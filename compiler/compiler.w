import lib.lib
import compiler.tokenizer
import compiler.analysis
import codegen
# P2: --profile-use (before the grammar, whose loop emitters call it)
import compiler.profile_use
import lib.assert
import compiler.type_table
import compiler.symbol_table
# Register promotion pre-scan and decision (reads the symbol and type
# tables; the grammar's function rule calls it)
import compiler.regalloc_scan
import compiler.lint
import grammar
# C3.1: check --all-errors state capture, after the grammar it reads
import compiler.analysis_state
import compiler.test_registry
import lib.sha256


void file_not_found_error():
	print_error(c"file '")
	print_error(filename)
	print_error(c"' not found error '")
	# 'file' holds the failed open() result; the old code passed the
	# error() function itself, which the typed checks now reject
	print_error(itoa(file))
	print_error(c"'\x0a")


# --quiet: suppress the non-diagnostic stderr chatter (the per-file
# "compiling '...'" banner, the target-mode banner and the absolute-path
# notice) so 'w check --json --quiet' emits pure NDJSON with an empty
# stderr on warning-free files. Diagnostics are never suppressed.
int quiet_mode


# --stats: print the symbol-lookup counters (compiler/symbol_table.w) to
# stderr once the compile finishes. Records visited is deterministic for a
# given input, so it is the figure to compare when changing lookup, and
# the one a test can assert; wall time is too noisy to gate on.
int stats_mode

# The tree query retains the entire implicit runtime and explicit input closure.
int retained_query_mode
int analysis_requested


# 'w deps' recording: while deps_mode is set, every file the compiler
# successfully opens for compilation (the root, every import, and the
# auto-imported runtime modules) is recorded here so deps_dump() can
# print the transitive import closure after the compile finishes.
int deps_mode
char* deps_paths
int deps_count

# 'w deps --json' shadow report (--import-root): while deps_mode is set
# and roots are in use, compile_relative_path probes every candidate for
# an import before compiling the first and parks the others here
# (newline-separated absolute paths, or 0); deps_record moves them onto
# that file's record, parallel to deps_paths.
char* deps_pending_shadows
char* deps_shadow_lists

# 'w defhash' scoping flags, declared here (rather than down with the
# rest of the defhash machinery, next to deps_dump/deps_main below) so
# compile_save can reference defhash_depth -- compile_save is defined
# well before that point in this file. See the big defhash doc comment
# by defhash_main for what these mean.
int defhash_closure_mode
int defhash_depth


void deps_record(char* path):
	int max_deps = 4000
	if (deps_paths == 0):
		deps_paths = cast(char*, malloc(max_deps * __word_size__))
		deps_shadow_lists = cast(char*, malloc(max_deps * __word_size__))
	assert1(deps_count < max_deps)
	save_ptr(deps_paths + deps_count * __word_size__, cast(int, strclone(path)))
	save_ptr(deps_shadow_lists + deps_count * __word_size__, cast(int, deps_pending_shadows))
	deps_pending_shadows = 0
	deps_count = deps_count + 1


# Repoint the diagnostic globals at the missing path before erroring
# about it. The upward search frees every candidate path it tried, and
# at cold start (the container-runtime auto-import, before any file has
# opened) filename and token are still null — either way error()'s
# human and JSON formatters must not read the stale pointers (#190).
# Only called on paths that end in error(), which exits (or longjmps to
# the REPL prompt, where token is already a live tokenizer buffer).
void missing_file_reset(char* path):
	filename = path
	line_number = 0
	diag_token_line = 0
	diag_token_column = 0
	if (token == 0): token = path


int compile_attempt(char* fn):
	# The caller owns fn and frees it after a failed attempt, so a
	# failure must not leave the global filename pointing at it: the
	# search-exhausted diagnostic would print the freed bytes (#190)
	char* old_filename = filename
	filename = fn
	file = open(filename, 0, 511)
	if (file < 0):
		if (verbosity >= 1): file_not_found_error()
		filename = old_filename
		return 0
	if (ast_retain_mode):
		int source = retained_source_begin(filename)
		if (retained_pending_import != 0): retained_sources[source].import_key = strclone(retained_pending_import)
	if (deps_mode): deps_record(filename)
	lint_note_open(filename)
	getchar_reset(file)
	line_number = 0
	column_number = 0
	tab_level = 0
	byte_offset = 0
	# Every file (root or import) starts parsing at nesting depth 0: an
	# import statement only ever appears at a file's own top level, never
	# inside a deeply nested expression or block, so these are already 0
	# by the time an import reaches here in practice -- reset explicitly
	# anyway so a compile that somehow starts already-nested (a future
	# caller, or a REPL path that reuses compile_attempt) can never carry
	# a stale count into a file that has not parsed anything yet.
	expr_nesting_depth = 0
	stmt_nesting_depth = 0
	# A nested compile_attempt (an import, via compile_save below) starts
	# while the importer's own nextc still holds its own mid-token
	# lookahead -- for an import statement specifically, the newline that
	# ends the 'import ...' line, not yet consumed (grammar/import_statement.w's
	# read_until_end() stops right before it). Left alone, the very first
	# get_character() call below (the priming read for this brand-new
	# file) would see that stale lookahead, misread it as "this file's own
	# previous character was a newline", and spuriously bump line_number
	# from 0 to 1 before a single byte of the new file has been read --
	# every diagnostic in the imported file then reports one line high.
	# Resetting nextc to 0 first reproduces the same "no previous
	# character" state every file sees at the true start of compilation
	# (nextc's own zero-initialized default), so the priming read is
	# unaffected by whatever the caller was in the middle of.
	nextc = 0
	nextc = get_character()
	# Silently skip a single UTF-8 byte-order mark (EF BB BF) at the very
	# start of the file -- some Windows editors emit one unprompted, and
	# without this the BOM's first byte becomes a bogus token (#287).
	# Matches Python 3 / Go / Rust. getc() keeps byte_offset exact while
	# leaving the line/column counters untouched, so a BOM file reports
	# the same diagnostic positions as its BOM-less twin. A file starting
	# with a partial match (a stray EF not followed by BB BF) is not W
	# source: it still fails on its first token, as before.
	if (nextc == 239):
		if (getc() == 187):
			if (getc() == 191): nextc = getc()
	get_token()
	int outer_retained_parent = retained_parent
	retained_parent = -1
	program()
	retained_parent = outer_retained_parent
	return 1


# Normalize path separators in-place: replace every '\' (92) with '/' (47).
# Windows GetCurrentDirectoryA returns backslash-separated paths; the rest
# of the path logic uses '/' uniformly so cross-platform paths just work.
# Only active on Windows: on Unix a backslash is an ordinary filename
# character and must be left alone.
void path_normalize_sep(char* p):
	if (os_windows() == 0): return
	while (p[0] != 0):
		if (p[0] == 92): p[0] = 47
		p = p + 1


# Return 1 if the path is absolute: starts with '/' (Unix) or with a
# Windows drive letter and colon (e.g. 'C:\', 'C:/', 'c:').
int path_is_absolute(char* p):
	if (p[0] == 47): return 1
	# Windows drive letter: an ASCII letter at [0], colon at [1]. The
	# letter check keeps ':' in ordinary Unix filenames from matching
	# (and never reads p[1] when the string is empty).
	int first = p[0] | 32
	if ((first >= 'a') && (first <= 'z') && (p[1] == 58)): return 1
	return 0


int compile_joined(char* cwd, char* filename):

	# Compute path based on current directory
	char* joined = strjoin(cwd, c"/")

	char* joined2 = strjoin(joined, filename)
	# print_string("joined: ", joined2)
	free(joined)

	# Add the .w extension if not already present
	if (ends_with(joined2, c".w") == 0):
		char* joined3 = strjoin(joined2, c".w")
		free(joined2)
		joined2 = joined3

	# Attempt to compile the path. On success joined2 stays allocated:
	# it is the global filename now, and diagnostics may still print it
	# after this frame returns (#190). One path per compiled file leaks.
	int result = compile_attempt(joined2)
	if (result == 0): free(joined2)
	return result


# The raw argv[0] of this compiler process, recorded by main() (w.w)
# before any argument shifting. compile_relative_path's last-resort
# fallback derives the binary's own directory from it, so a compile
# started from outside the checkout (an agent's scratch directory) can
# still resolve the auto-imported container runtime that lives next to
# the compiler. Stays 0 for embedders with their own main (the REPL),
# which simply skips the fallback.
char* compiler_argv0


# Directory holding the compiler binary itself, derived from argv[0]:
# separators normalized, the last path component stripped, and a
# relative spelling ('./bin/wv2', 'bin/wv2') resolved against the
# current directory (the process never chdirs, so cwd still matches the
# invocation). Returns a fresh allocation the caller frees, or 0 when
# the directory cannot be known — no argv[0] was recorded, or argv[0]
# is a bare command name found via PATH.
char* compiler_binary_dir():
	if (compiler_argv0 == 0): return 0
	char* prog = strclone(compiler_argv0)
	path_normalize_sep(prog)
	int last_slash = 0 - 1
	int i = 0
	while (prog[i] != 0):
		if (prog[i] == 47): last_slash = i
		i = i + 1
	if (last_slash < 0):
		free(prog)
		return 0
	if (last_slash == 0):
		# '/wv2': keep the root itself as the directory
		prog[1] = 0
	else: prog[last_slash] = 0
	if (path_is_absolute(prog)):
		return prog
	int max_path_size = 4096
	char* cwd = cast(char*, malloc(max_path_size))
	getcwd(cwd, max_path_size)
	path_normalize_sep(cwd)
	char* joined = strjoin(cwd, c"/")
	char* absolute = strjoin(joined, prog)
	free(joined)
	free(cwd)
	free(prog)
	return absolute


# Walk 'dir' upward toward the filesystem root, attempting to compile
# dir/fn at each level. Mutates dir in place (callers pass a scratch
# copy). Returns 1 once a level compiled, 0 when every level failed.
int compile_search_upward(char* dir, char* fn):
	while (dir[0]):

		# Attempt to compile with this path
		int result = compile_joined(dir, fn)

		# If successfull return
		if (result == 1): return 1

		# Go back up one directory. A directory with no '/' left (the
		# Windows drive root "C:") ends the walk: Unix paths reach ""
		# at "/", but "C:" would otherwise be retried forever.
		int index = strlen(dir) - 1
		int went_up = 0
		while (index >= 0):
			if (dir[index] == 47):
				dir[index] = 0
				went_up = 1
				index = 0 /* hacky way to break from loop */
			index = index - 1
		if (went_up == 0): dir[0] = 0
		if (verbosity >= 1): print_string(c"went up one directory: ", dir)
	return 0


/*
--import-root <dir> (repeatable; also spelled --import-root=<dir>):
explicit, ordered module search roots (docs/projects/compilation_model.md
§7). An import's resolved module path (dots to slashes,
__arch__ already substituted by grammar/import_statement.w) is tried as
exactly <root>/<path>.w in each root in command-line order -- no upward
walk inside a root -- and the first root holding the file wins. Only when
no root does, the default search below runs unchanged (the working
directory and every parent, then the compiler binary's directory and
every parent), so with no roots every import resolves exactly as before.

import_roots_scan (called by link_impl before the auto-imported container
runtime compiles) collects the roots from the whole argument list, makes
each absolute against the invocation's working directory, cleans it
lexically ('.', '..', repeated and trailing separators) and rejects one
that is not a directory. The roots then apply to every import: user
imports, the auto-imported runtime and the on-demand runtimes alike.
Command-line input files are never searched for (compile_input_file).
Module dedupe stays on the module path ("lib/foo"), so a module name is
compiled once whichever root supplied it.
*/
char* import_roots
int import_root_count


char* import_root_at(int index):
	return cast(char*, load_ptr(import_roots + index * __word_size__))


# Lexically clean an absolute path: drop empty and '.' segments, let '..'
# remove the previous segment (never past the '/' or 'C:' prefix), and
# drop a trailing separator. Returns a fresh allocation.
char* import_root_clean(char* path):
	int n = strlen(path)
	char* out = cast(char*, malloc(n + 2))
	int len = 0
	int i = 0
	if (path[0] == '/'):
		out[0] = '/'
		len = 1
		i = 1
	else:
		# Windows drive prefix ('C:'), kept as the floor '..' cannot pop
		while ((path[i] != 0) && (path[i] != '/')):
			out[len] = path[i]
			len = len + 1
			i = i + 1
	int floor = len
	while (path[i] != 0):
		if (path[i] == '/'): i = i + 1
		else:
			int j = i
			while ((path[j] != 0) && (path[j] != '/')): j = j + 1
			int seg = j - i
			int is_dot = (seg == 1) && (path[i] == '.')
			int is_dotdot = (seg == 2) && (path[i] == '.') && (path[i + 1] == '.')
			if (is_dotdot):
				while ((len > floor) && (out[len - 1] != '/')): len = len - 1
				if (len > floor): len = len - 1
			else if (is_dot == 0):
				if ((len > 0) && (out[len - 1] != '/')):
					out[len] = '/'
					len = len + 1
				while (i < j):
					out[len] = path[i]
					len = len + 1
					i = i + 1
			i = j
	out[len] = 0
	return out


# A directory opens as '<dir>/.'; a regular file there fails with
# ENOTDIR. (On Windows the open helper passes FILE_FLAG_BACKUP_SEMANTICS,
# so a directory opens too.)
int import_root_is_dir(char* dir):
	char* probe = strjoin(dir, c"/.")
	int fd = open(probe, 0, 0)
	free(probe)
	if (fd < 0): return 0
	close(fd)
	return 1


# A bad --import-root fails before anything compiles, with the option
# text; under --json as one NDJSON record at the "<command-line>" marker
# (the unrecognized_option_error shape below).
void import_root_error(char* message, char* arg):
	diag_part(message)
	diag_part(c"'")
	diag_part(arg)
	diag_part(c"'")
	if (diag_json): diag_emit(c"error", c"<command-line>", 0, 0, arg)
	else:
		print_error(c"error: ")
		print_error(str_from_cstr(diag_buffer))
		print_error(c"\x0a")
	exit(1)


void import_root_add(char* spelled):
	if (spelled[0] == 0): import_root_error(c"missing directory after ", c"--import-root")
	char* path = strclone(spelled)
	path_normalize_sep(path)
	char* absolute = path
	if (path_is_absolute(path) == 0):
		int max_path_size = 4096
		char* cwd = cast(char*, malloc(max_path_size))
		getcwd(cwd, max_path_size)
		path_normalize_sep(cwd)
		char* joined = strjoin(cwd, c"/")
		absolute = strjoin(joined, path)
		free(joined)
		free(cwd)
	char* cleaned = import_root_clean(absolute)
	if (import_root_is_dir(cleaned) == 0): import_root_error(c"import root is not a directory: ", spelled)
	int max_roots = 64
	if (import_roots == 0): import_roots = cast(char*, malloc(max_roots * __word_size__))
	if (import_root_count >= max_roots): import_root_error(c"too many import roots at ", spelled)
	save_ptr(import_roots + import_root_count * __word_size__, cast(int, cleaned))
	import_root_count = import_root_count + 1


# How many arguments an --import-root option occupies at arg: 2 for the
# separate-value spelling, 1 for '--import-root=<dir>', 0 when arg is
# not one. The subcommands' leading-flag loops skip over them, and
# link_impl's scans treat the separate value like -o's.
int import_root_arg_width(char* arg):
	if (strcmp(arg, c"--import-root") == 0): return 2
	if (starts_with(arg, c"--import-root=")): return 1
	return 0


# Collect every --import-root in argv[1..argc), in order. The whole
# argument list is scanned (not just from link_impl's start index), so
# the option works wherever it appears after the subcommand word.
void import_roots_scan(int argc, int argv):
	import_root_count = 0
	int k = 1
	while (k < argc):
		char** arg = argv + k * __word_size__
		if (strcmp(*arg, c"-o") == 0): k = k + 1
		else if (import_root_arg_width(*arg) == 2):
			if (k + 1 >= argc): import_root_error(c"missing directory after ", *arg)
			char** value = argv + (k + 1) * __word_size__
			import_root_add(*value)
			k = k + 1
		else if (import_root_arg_width(*arg) == 1): import_root_add(*arg + 14)
		k = k + 1


# Probe-only twin of compile_search_upward: the first dir/fn that opens,
# walking dir (mutated) toward the root; a fresh allocation, or 0.
char* import_probe_upward(char* dir, char* fn):
	while (dir[0]):
		char* joined = strjoin(dir, c"/")
		char* candidate = strjoin(joined, fn)
		free(joined)
		int fd = open(candidate, 0, 0)
		if (fd >= 0):
			close(fd)
			return candidate
		free(candidate)
		int index = strlen(dir) - 1
		while ((index >= 0) && (dir[index] != 47)): index = index - 1
		if (index < 0): dir[0] = 0
		else: dir[index] = 0
	return 0


# text + "\n" + path (or a copy of path when text is 0); frees text.
char* import_shadow_append(char* text, char* path):
	if (text == 0): return strclone(path)
	char* with_sep = strjoin(text, c"\x0a")
	free(text)
	char* result = strjoin(with_sep, path)
	free(with_sep)
	return result


# The probe path <root>/fn for root index r; a fresh allocation.
char* import_root_candidate(int r, char* fn):
	char* joined = strjoin(import_root_at(r), c"/")
	char* candidate = strjoin(joined, fn)
	free(joined)
	return candidate


int import_path_opens(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0): return 0
	close(fd)
	return 1


# deps --json with roots: every file this import could resolve to -- each
# root's <root>/fn, then the default search's first hit -- minus the
# first (the one the compile takes) goes to deps_pending_shadows. A
# default hit that is the very same path as a root candidate (a root
# naming the working directory) is not a second file.
void import_root_note_shadows(char* fn):
	char* found = 0
	int found_count = 0
	for r in range(import_root_count):
		char* candidate = import_root_candidate(r, fn)
		if (import_path_opens(candidate)):
			if (found_count > 0): found = import_shadow_append(found, candidate)
			found_count = found_count + 1
		free(candidate)
	int max_path_size = 4096
	char* cwd = cast(char*, malloc(max_path_size))
	getcwd(cwd, max_path_size)
	path_normalize_sep(cwd)
	char* fallback = import_probe_upward(cwd, fn)
	free(cwd)
	if (fallback == 0):
		char* bin_dir = compiler_binary_dir()
		if (bin_dir != 0):
			fallback = import_probe_upward(bin_dir, fn)
			free(bin_dir)
	if ((fallback != 0) && (found_count > 0)):
		int same = 0
		for r2 in range(import_root_count):
			char* again = import_root_candidate(r2, fn)
			if (strcmp(again, fallback) == 0): same = 1
			free(again)
		if (same == 0): found = import_shadow_append(found, fallback)
	if (fallback != 0): free(fallback)
	deps_pending_shadows = found


# fn must not shadow the global filename: the search-exhausted branch
# below reads and repoints the global.
int compile_relative_path(char* fn):
	# Explicit --import-root roots first, in order (block comment above)
	if (import_root_count > 0):
		if (deps_mode): import_root_note_shadows(fn)
		for r in range(import_root_count):
			if (compile_joined(import_root_at(r), fn)): return 1
		deps_pending_shadows = 0

	# Get current directory
	int max_path_size = 4096
	char* cwd = cast(char*, malloc(max_path_size))
	getcwd(cwd, max_path_size)
	# Normalize backslashes from Windows GetCurrentDirectoryA to forward slashes
	path_normalize_sep(cwd)

	if (compile_search_upward(cwd, fn)):
		free(cwd)
		return 1
	free(cwd)

	# Last resort: the same upward walk from the compiler binary's own
	# directory (argv[0]). With the CWD in a scratch directory outside
	# the checkout, this is what lets '/repo/bin/wv2 check snippet.w'
	# still resolve 'structures/hash_table.w' and the rest of the
	# auto-imported runtime living next to the compiler.
	char* bin_dir = compiler_binary_dir()
	if (bin_dir != 0):
		if (compile_search_upward(bin_dir, fn)):
			free(bin_dir)
			return 1
		free(bin_dir)

	# Point the diagnostic at the import statement when an importing
	# file is current; at cold start (the auto-imported container
	# runtime) fall back to the searched path itself.
	if (filename == 0): missing_file_reset(fn)
	# A path-shaped spelling ('import lib/assert.w') mangles into a
	# nonsense search path ('lib/assert/w.w') during dots-to-slashes
	# resolution: echo the import line as the user wrote it and hint
	# the dotted form instead (grammar/import_statement.w).
	if ((import_current_spelling != 0) && import_spelling_path_shaped(import_current_spelling)):
		diag_part(c"cannot locate '")
		diag_part(import_current_spelling)
		error3(c"': import paths are dotted module names, not file paths; try 'import ", import_spelling_dotted(import_current_spelling), c"'")
		return 0
	diag_part(c"cannot locate '")
	diag_part(fn)
	# error() instead of exit() so a REPL entry importing a missing
	# module recovers to the prompt instead of killing the session
	if (import_root_count > 0): error(c"' (searched the import roots, the current directory and every parent)")
	else: error(c"' (searched the current directory and every parent)")
	return 0


int compile_file(char* filename):
	# Handle absolute paths by using the filename directly
	# (Unix '/' prefix or Windows drive letter like 'C:')
	path_normalize_sep(filename)
	if (path_is_absolute(filename)):
		if (quiet_mode == 0):
			print2(c"using filename as path directly: ")
			println2(filename)
		return compile_attempt(filename)

	return compile_relative_path(filename)


# Top-level inputs — command-line files and the REPL/wdbg targets — do
# not get the upward directory search that imports do: a mistyped path
# fails immediately with one "no such file" diagnostic instead of a
# noisy retry per parent directory ending in a garbled abandon message
# (#190, docs/projects/ai_tooling_next_steps.md).
int compile_input_file(char* path):
	path_normalize_sep(path)
	if (path_is_absolute(path)):
		if (compile_attempt(path)): return 1
	else:
		int max_path_size = 4096
		char* cwd = cast(char*, malloc(max_path_size))
		getcwd(cwd, max_path_size)
		path_normalize_sep(cwd)
		int result = compile_joined(cwd, path)
		free(cwd)
		if (result): return 1
	missing_file_reset(path)
	error3(c"no such file: '", path, c"'")
	return 0


void compile_save(char* fn):
	char* old_filename = filename
	int old_file = file
	int old_line_number = line_number
	int old_column_number = column_number
	int old_diag_token_line = diag_token_line
	int old_diag_token_column = diag_token_column
	int old_tab_level = tab_level
	int old_byte_offset = byte_offset
	# Saved (and restored below) so the importer's own pending lookahead
	# survives the nested compile: import_statement() left nextc holding
	# the not-yet-consumed newline at the end of the 'import ...' line
	# (read_until_end() stops right before it), and the caller's own
	# 'nextc = get_character()' right after this call relies on seeing
	# that same newline to correctly advance line_number past it. Without
	# this, nextc comes back holding whatever the imported file's own
	# tokenizing left it as (its own EOF-ish sentinel), that follow-up
	# read silently fails to notice a newline was crossed, and every
	# diagnostic for the rest of the importing file reports one line low.
	int old_nextc = nextc

	# Import aliases and plain-import records are file-scoped: hide the
	# importer's entries while the imported file compiles, then drop the
	# imported file's entries on the way back out.
	int old_alias_base = import_alias_base
	int old_alias_count = import_alias_count
	int old_plain_base = import_plain_base
	int old_plain_count = import_plain_count
	import_alias_base = import_alias_count
	import_plain_base = import_plain_count

	if (verbosity >= 0): print_string(c"compiling ", fn)

	# defhash's root-vs-import scoping (defhash_note, above) reads this:
	# 0 while the tokens just parsed belong directly to a command-line
	# root argument, >0 while inside an import's own nested compile.
	# Bracketing compile_file() here covers every import, direct or
	# transitive (including the auto-imported container-runtime closure,
	# which reaches this same path through import_module).
	defhash_depth = defhash_depth + 1
	lint_depth = lint_depth + 1
	compile_file(fn)
	close(file)
	lint_depth = lint_depth - 1
	defhash_depth = defhash_depth - 1

	filename = old_filename
	file = old_file
	line_number = old_line_number
	column_number = old_column_number
	diag_token_line = old_diag_token_line
	diag_token_column = old_diag_token_column
	tab_level = old_tab_level
	byte_offset = old_byte_offset
	nextc = old_nextc
	import_alias_base = old_alias_base
	import_alias_count = old_alias_count
	import_plain_base = old_plain_base
	import_plain_count = old_plain_count

	# filename is still null when the importer was the cold-start
	# auto-import (no file was open yet); print_string on a null string
	# faults, and -v makes this level reachable now.
	if ((verbosity >= 0) && (filename != 0)): print_string(c"back to ", filename)


# The recognized target-selector words, shared by link_impl's positional
# parse and the selector-first subcommand spelling ('w x64 check f.w')
# that main() forwards through target_pending.
int target_is_selector(char* arg):
	if (strcmp(arg, c"x64") == 0): return 1
	if (strcmp(arg, c"arm64") == 0): return 1
	if (strcmp(arg, c"arm64_darwin") == 0): return 1
	if (strcmp(arg, c"arm64_ios") == 0): return 1
	if (strcmp(arg, c"arm64_ios_sim") == 0): return 1
	if (strcmp(arg, c"win64") == 0): return 1
	if (strcmp(arg, c"wasm") == 0): return 1
	return 0


# A selector spelled before a subcommand word ('w x64 deps f.w') is
# recorded here by main() and applied by link_impl right after its
# target-state reset, so check/deps/symbols compose with the target
# selector in either spelling.
char* target_pending


# Apply one selector word to the target-mode globals; returns 1 when the
# word selected a target, 0 when it is not a selector.
int target_selector_apply(char* arg):
	if (strcmp(arg, c"x64") == 0):
		if (quiet_mode == 0): println2(c"Compiling in x64 mode")
		word_size =  8
		word_size_log2 = 3
		diag_word_size = word_size
		# W^X (docs/projects/wx_split.md Stage B): mutable globals, GOT
		# slots and extern-data copy space go to a separate read-write
		# data segment; the code segment is mapped read-execute.
		data_split = 1
		return 1
	if (strcmp(arg, c"arm64") == 0):
		if (quiet_mode == 0): println2(c"Compiling in arm64 mode")
		# AArch64 is a 64-bit target, so it inherits the x64 type system
		# (8-byte pointers, int64, float64); target_isa selects the A64
		# instruction emitter and the Mach-O/ELF-arm64 container.
		word_size = 8
		word_size_log2 = 3
		diag_word_size = word_size
		target_isa = 1
		# W^X: arm64 executables get a read-execute code segment and a
		# separate read-write data segment (docs/projects/arm64.md Stage
		# 3; the split now covers every file target, see
		# docs/projects/wx_split.md).
		data_split = 1
		return 1
	if (strcmp(arg, c"wasm") == 0):
		if (quiet_mode == 0): println2(c"Compiling in wasm mode")
		# wasm32 + WASI (docs/projects/wasm_backend.md): 32-bit words like
		# the default target; target_isa selects the wasm instruction
		# emitter and target_os the module container writer. The text/data
		# split is mandatory — wasm code is not addressable memory.
		word_size = 4
		word_size_log2 = 2
		diag_word_size = word_size
		target_isa = 2
		target_os = 3
		data_split = 1
		return 1
	if (strcmp(arg, c"win64") == 0):
		if (quiet_mode == 0): println2(c"Compiling in win64 mode")
		# Windows x64: the x86-64 instruction emitter (target_isa 0,
		# word_size 8) with the PE32+ container and a kernel32-import
		# runtime instead of Linux syscalls (docs/projects/windows.md).
		word_size = 8
		word_size_log2 = 3
		diag_word_size = word_size
		target_os = 2
		# W^X (docs/projects/wx_split.md Stage A): IAT slots and mutable
		# globals go to a read-write .data section so the loader's IAT
		# bind never targets an executable page -- under HVCI Windows
		# drops such writes and every import stays unresolved.
		data_split = 1
		return 1
	if ((strcmp(arg, c"arm64_darwin") == 0) || (strcmp(arg, c"arm64_ios") == 0) || (strcmp(arg, c"arm64_ios_sim") == 0)):
		if (quiet_mode == 0):
			print2(c"Compiling in ")
			print2(arg)
			println2(c" mode")
		target_apple_platform = 1
		if (strcmp(arg, c"arm64_ios") == 0): target_apple_platform = 2
		if (strcmp(arg, c"arm64_ios_sim") == 0): target_apple_platform = 7
		# Same A64 instruction emitter and 64-bit type system as the
		# arm64 (Linux) target; target_os selects the Darwin syscall
		# stubs and the Mach-O container writer (Stage 4).
		word_size = 8
		word_size_log2 = 3
		diag_word_size = word_size
		target_isa = 1
		target_os = 1
		data_split = 1
		return 1
	return 0


# Canonical import-registry form of a command-line root path: separators
# normalized, a leading './' and the '.w' extension stripped — the same
# shape import_module() registers for an import line ('import
# compiler.compiler' registers "compiler/compiler"), so roots and imports
# dedupe against each other no matter which direction they arrive in.
# Returns a fresh allocation.
char* root_canonical(char* path):
	char* normalized = strclone(path)
	path_normalize_sep(normalized)
	char* trimmed = normalized
	if (starts_with(trimmed, c"./")): trimmed = trimmed + 2
	char* canonical = strclone(trimmed)
	free(normalized)
	if (ends_with(canonical, c".w")): canonical[strlen(canonical) - 2] = 0
	return canonical


# Compiler-internal modules only compile inside w.w's import graph;
# checking one standalone dies with a misleading missing-symbol error in
# whatever neighbor happens to be referenced first. So in check mode (and
# the check-shaped deps/symbols subcommands) such a root is substituted
# with w.w — the gate that actually matters for a compiler change — and a
# one-line stderr note says so. The exact rule: a root is
# compiler-internal when its canonical path (relative, as spelled from
# the repo root, './' and '.w' stripped) starts with 'compiler/',
# 'grammar/', 'code_generator/' or 'debugger/', or is exactly 'codegen'
# or 'grammar' (the two top-level umbrella modules). Absolute or
# differently-anchored spellings are not recognized and compile as
# given. In a mixed argument list only the internal roots are
# substituted; the root dedupe in link_impl collapses repeated w.w
# substitutions into one compile.
int root_is_compiler_internal(char* path):
	char* canonical = root_canonical(path)
	int internal = 0
	if (starts_with(canonical, c"compiler/")): internal = 1
	if (starts_with(canonical, c"grammar/")): internal = 1
	if (starts_with(canonical, c"code_generator/")): internal = 1
	if (starts_with(canonical, c"debugger/")): internal = 1
	if (strcmp(canonical, c"codegen") == 0): internal = 1
	if (strcmp(canonical, c"grammar") == 0): internal = 1
	free(canonical)
	return internal


# -v/--verbose: raise the verbosity from its quiet default (-1, set by
# main() in w.w). The first flag reaches level 0 -- the user-facing
# verbose level: the per-import banners (compile_save) and the c_import
# skip notes (libs/extras/c_import/importer.w). Levels 1 and up remain
# the compiler-developer debug traces (per-expression promote() dumps,
# per-symbol declarations, ...); each further flag adds one level.
void verbosity_raise():
	if (verbosity < 0): verbosity = 0
	else: verbosity = verbosity + 1


# Every dash-prefixed option link_impl understands, in one place so the
# up-front validation and the positional flag loop agree on the set; -o
# is excluded because its argument-consuming form needs special
# handling at both call sites. Returns 1 when arg is an option; with
# apply set, also applies its positional effect. The whole-program
# options (--pac, --wasm-acc, -v/--verbose) take effect in link_impl's
# pre-scans, so here they are only recognized.
int link_option(char* arg, int apply):
	if (strcmp(arg, c"--pie") == 0): return 1
	if (strcmp(arg, c"--shared") == 0): return 1
	if (strcmp(arg, c"--static") == 0): return 1
	if (starts_with(arg, c"--link=")): return 1
	if (strcmp(arg, c"--syscall-abi=vmcall") == 0 || strcmp(arg, c"--syscall-abi=linux") == 0): return 1
	if ((strcmp(arg, c"--bounds=on") == 0) || (strcmp(arg, c"--bounds=trap") == 0)):
		if (apply): bounds_mode = 1
		return 1
	if (strcmp(arg, c"--bounds=off") == 0):
		if (apply): bounds_mode = 0
		return 1
	if (strcmp(arg, c"--strict") == 0):
		if (apply): strict_mode = 1
		return 1
	# Compile every function's portable W body, ignoring asm blocks
	# (grammar/asm_function.w).
	if (strcmp(arg, c"--no-asm") == 0):
		if (apply): asm_bodies_disabled = 1
		return 1
	if (strcmp(arg, c"--ast-expressions") == 0):
		if (apply && (ast_expressions_mode < 2)): ast_expressions_mode = 1
		return 1
	if (strcmp(arg, c"--ast-full-expressions") == 0):
		if (apply): ast_expressions_mode = 2
		return 1
	if (strcmp(arg, c"--ast-retain") == 0):
		if (apply):
			ast_expressions_mode = 2
			ast_retain_mode = 1
			# P1.2b: an explicit request keeps the semantic records too.
			retained_semantic_mode = 1
		return 1
	if (strcmp(arg, c"--ast-audit") == 0):
		if (apply):
			ast_expressions_mode = 2
			ast_audit_mode = 1
		return 1
	if (strcmp(arg, c"--ast-required") == 0):
		if (apply):
			ast_expressions_mode = 2
			ast_required_mode = 1
		return 1
	# S2.1: emit expressions from the retained forest (implies --ast-retain).
	# S2.5: the default for every compile (link_impl), like --ast-retain;
	# both stay accepted and still conflict with --streaming.
	if (strcmp(arg, c"--ast-emit-retained") == 0):
		if (apply):
			ast_expressions_mode = 2
			ast_retain_mode = 1
			ast_emit_retained_mode = 1
		return 1
	# P1.4: the AST front end is the default (link_reset). --streaming opts
	# out for the whole program, implicit runtime imports included, so
	# link_impl's flag pre-scan applies it and this only recognizes it.
	if (strcmp(arg, c"--streaming") == 0): return 1
	# C3.5: the optional optimizer pass (compiler/ast_opt.w). Whole-program,
	# so link_impl's flag pre-scan applies it; it conflicts with --streaming.
	if (strcmp(arg, c"--ast-opt") == 0):
		if (apply): ast_opt_mode = 1
		return 1
	# P1 (docs/projects/register_allocation_pgo.md §3.2): instrumented
	# execution counters per function and loop head, flushed at exit to
	# $W_PROFILE_OUT, with a <output>.wprofmap sidecar keyed by defhash
	# (code_generator/profile_counters.w, lib/profile.w). Whole-program:
	# link_impl's flag pre-scan applies it before the first file compiles.
	# The map needs the definition spans defhash_note records, so the
	# flag arms defhash recording over the whole closure; defhash_dump
	# itself stays with 'w defhash'. x86/x64/arm64 Linux ELF only.
	if ((strcmp(arg, c"--profile-generate") == 0) || (strcmp(arg, c"--coverage") == 0)):
		if (apply):
			if (((target_isa != 0) && (target_isa != 1)) || (target_os != 0)):
				print_error(c"error: ")
				print_error(arg)
				print_error(c" is only supported on the x86, x64 and arm64 Linux targets\x0a")
				exit(1)
			if (strcmp(arg, c"--coverage") == 0): coverage_generate_mode = 1
			profile_generate_mode = 1
			defhash_mode = 1
			defhash_closure_mode = 1
		return 1
	# P2 (docs/projects/register_allocation_pgo.md §3.4-§3.5): read one
	# .wprof profile (bin/wprof's output) and let it classify functions
	# as hot/cold and mark hot loop heads for alignment
	# (compiler/profile_use.w). Whole-program, like --profile-generate:
	# link_impl's flag pre-scan applies it before the runtime closure
	# compiles. Explicit only: no flag, no profile, no change in output.
	if (starts_with(arg, c"--profile-use=")):
		if (apply): profile_use_load(arg + 14)
		return 1
	if (strcmp(arg, c"--quiet") == 0):
		if (apply): quiet_mode = 1
		return 1
	if (strcmp(arg, c"--stats") == 0):
		if (apply): stats_mode = 1
		return 1
	if (strcmp(arg, c"--stats-selfcheck") == 0):
		if (apply): sym_index_selfcheck = 1
		return 1
	# Register promotion of hot locals (docs/projects/register_allocation_pgo.md
	# §2.2) is on by default on x86/x64 Linux; --no-regs (alias -O0) keeps
	# every local on the stack, which is the reference for
	# tests/regalloc_diff_test.w and the fallback a guard failure asks for.
	if ((strcmp(arg, c"--no-regs") == 0) || (strcmp(arg, c"-O0") == 0)):
		if (apply): regalloc_disabled = 1
		# -O0 is "no optimization": the condition chains, the
		# bottom-tested loops and the expression registers go too
		if (apply && (strcmp(arg, c"-O0") == 0)):
			cond_branch_disabled = 1
			loop_rotate_disabled = 1
			ers_disabled = 1
			ivopt_disabled = 1
		return 1
	if (strcmp(arg, c"--regs") == 0):
		if (apply): regalloc_disabled = 0
		return 1
	# Direct calls (docs/projects/codegen_gap_plan.md §2.4, unit A4) are
	# on by default on x86/x64; --no-direct-calls reloads every callee
	# into the accumulator, the reference for tests/regalloc_diff_test.w
	# and the fallback a guard failure asks for.
	if (strcmp(arg, c"--no-direct-calls") == 0):
		if (apply): direct_calls_disabled = 1
		return 1
	# Addressing modes (docs/projects/codegen_gap_plan.md §2.2, unit A2)
	# are on by default on x86/x64; --no-addr-modes keeps the
	# accumulator-address loads and stores, the reference for
	# tests/regalloc_diff_test.w.
	if (strcmp(arg, c"--no-addr-modes") == 0):
		if (apply): addr_modes_disabled = 1
		return 1
	# The expression register stack (docs/projects/codegen_gap_plan.md
	# §2.3, unit A3) is on by default on x86/x64; --no-expr-regs (and
	# -O0) parks every waiting operand on the real stack, the reference
	# for tests/regalloc_diff_test.w and the fallback an internal error
	# asks for.
	if (strcmp(arg, c"--no-expr-regs") == 0):
		if (apply): ers_disabled = 1
		return 1
	if (strcmp(arg, c"--expr-regs") == 0):
		if (apply): ers_disabled = 0
		return 1
	# The x86-32 register budget (docs/projects/codegen_gap_plan.md §2.7,
	# unit A9: loops own ecx/edx where no shift count or division needs
	# them) is on by default; --no-x86-budget keeps the pre-A9 budget,
	# the reference for tests/regalloc_diff_test.w. Nothing on x64.
	if (strcmp(arg, c"--no-x86-budget") == 0):
		if (apply): x86_budget_disabled = 1
		return 1
	if (strcmp(arg, c"--x86-budget") == 0):
		if (apply): x86_budget_disabled = 0
		return 1
	# Branch-on-flags for &&/||/! in conditions (docs/projects/
	# codegen_gap_plan.md §2.6, grammar/cond_branch.w) is on by default
	# on x86/x64; --no-cond-branch (and -O0) keeps the value form, which
	# is the reference for tests/regalloc_diff_test.w.
	if (strcmp(arg, c"--no-cond-branch") == 0):
		if (apply): cond_branch_disabled = 1
		return 1
	if (strcmp(arg, c"--cond-branch") == 0):
		if (apply): cond_branch_disabled = 0
		return 1
	# Loop rotation (docs/projects/codegen_gap_plan.md §2.5, unit A7,
	# grammar/while_statement.w) is on by default on x86/x64 and arm64;
	# --no-loop-rotate (and -O0) keeps every loop top-tested, the
	# reference for tests/regalloc_diff_test.w.
	if (strcmp(arg, c"--no-loop-rotate") == 0):
		if (apply): loop_rotate_disabled = 1
		return 1
	if (strcmp(arg, c"--loop-rotate") == 0):
		if (apply): loop_rotate_disabled = 0
		return 1
	# Induction-variable pointers (compiler/ivopt.w, unit O7) are on by
	# default on x64; --no-ivopts (and -O0) keeps every subscript's own
	# address arithmetic, the reference for tests/regalloc_diff_test.w.
	if (strcmp(arg, c"--no-ivopts") == 0):
		if (apply): ivopt_disabled = 1
		return 1
	if (strcmp(arg, c"--ivopts") == 0):
		if (apply): ivopt_disabled = 0
		return 1
	# Narrow integer promotion (docs/projects/codegen_gap_plan.md §2.7,
	# unit A8): int32/uint32 locals and arguments take registers like
	# 'int' on x86/x64; --no-narrow-regs keeps them on the stack, the
	# reference for tests/regalloc_diff_test.w.
	if (strcmp(arg, c"--no-narrow-regs") == 0):
		if (apply): narrow_regs_disabled = 1
		return 1
	if (strcmp(arg, c"--narrow-regs") == 0):
		if (apply): narrow_regs_disabled = 0
		return 1
	# Inlining of small leaf callees (unit A5, compiler/inline_table.w)
	# is on by default on x86/x64 Linux for tiny leaves only: --inline
	# raises the budgets, --profile-use raises them for the sites the
	# profile marks hot, and --no-inline keeps every call a call
	# whatever else was given (the reference for
	# tests/regalloc_diff_test.w and the fallback a guard failure asks
	# for).
	if (strcmp(arg, c"--inline") == 0):
		if (apply): inline_requested = 1
		return 1
	if (strcmp(arg, c"--no-inline") == 0):
		if (apply): inline_disabled = 1
		return 1
	if (starts_with(arg, c"--ptx=")):
		# Debug dump of the embedded PTX module (kernels/'gpu for'),
		# written by ptx_finish_module; ignored when no kernels exist.
		if (apply): ptx_dump_path = arg + 6
		return 1
	if (starts_with(arg, c"--cubin-file=")):
		# Opt-in pre-compiled GPU image (ptxas output for the --ptx
		# dump), embedded by ptx_finish_cubin; the runtime tries it
		# before JIT-loading the PTX (docs/projects/cuda.md).
		if (apply): ptx_cubin_path = arg + 13
		return 1
	if ((strcmp(arg, c"--pac=off") == 0) || (strcmp(arg, c"--pac=ret") == 0) || (strcmp(arg, c"--pac=full") == 0)):
		return 1
	if ((strcmp(arg, c"--wasm-acc=globals") == 0) || (strcmp(arg, c"--wasm-acc=locals") == 0)):
		return 1
	# --import-root=<dir> is whole-program too (import_roots_scan)
	if (import_root_arg_width(arg) == 1): return 1
	return (strcmp(arg, c"-v") == 0) || (strcmp(arg, c"--verbose") == 0)


# --help/-h: the full documented flag surface, one line per flag, on
# stdout (explicitly requested output, unlike the bare stderr usage
# lines printed when arguments are missing). skills_test asserts that
# every compiler flag documented in AGENTS.md, README.md and
# .cursor/skills/ appears in this output, so keep these lists complete
# when adding a flag.
void help_shared_options():
	println(c"  -o <path>             write the executable to <path> (mode 0755)")
	println(c"  --bounds=on|off|trap  array bounds checks: on (default), off, or trap")
	println(c"  --pac=off|ret|full    arm64 pointer-authentication level (default: ret)")
	println(c"  --strict              treat warnings as errors and write no output")
	println(c"  --no-asm              compile portable W bodies, ignoring 'asm <isa>:' blocks")
	println(c"  --streaming           use the streaming front end instead of the default AST one")
	println(c"  --ast-expressions     with --streaming: AST for grouped scalar expressions only")
	println(c"  --ast-full-expressions AST at every expression (the default; kept for scripts)")
	println(c"  --ast-audit           JSON fallback records on stderr for each streaming fallback")
	println(c"  --ast-retain          also keep semantic type/binding records in the forest (queries keep them)")
	println(c"  --ast-required        reject any expression fallback (coverage gate)")
	# S2.1
	println(c"  --ast-emit-retained   emit from the retained AST (the default; kept for scripts)")
	# C3.5
	println(c"  --ast-opt             fold constant if/while conditions and drop the dead arms")
	# P1
	println(c"  --coverage            count executable statement lines; report with wcoverage lines")
	println(c"  --profile-generate    count function entries and loop heads at run time; needs -o,")
	println(c"                        writes <output>.wprofmap; the program appends to $W_PROFILE_OUT")
	# P2
	println(c"  --profile-use=<path>  read a .wprof profile (bin/wprof merge): cold functions skip")
	println(c"                        register promotion, hot ones rank locals by measured loop")
	println(c"                        counts, hot loop heads are 16-byte aligned")
	println(c"  --quiet               suppress the non-diagnostic stderr banners")
	println(c"  --stats               print symbol-lookup counters to stderr when done")
	println(c"  --static              emit an x64 W compiled static library (.wa)")
	println(c"  --shared              emit an x64 Linux shared library (export functions)")
	println(c"  --link=<path>         link a shared library, repeatable")
	println(c"  --pie                 emit an x64 Linux position-independent executable")
	println(c"  --syscall-abi=vmcall   emit an x64 static KVM cell executable")
	println(c"  --stats-selfcheck     cross-check every symbol lookup against a linear scan")
	println(c"  --no-regs, -O0        keep every local on the stack (no register promotion)")
	println(c"  --no-cond-branch      materialize &&/||/! in conditions (no branch-on-flags chains); -O0 too")
	println(c"  --no-loop-rotate      keep while/for loops top-tested (no bottom-tested rotation); -O0 too")
	println(c"  --no-ivopts           no induction-variable pointers for array walks in loops (x64); -O0 too")
	println(c"  --regs                promote hot locals into callee-saved registers (default)")
	println(c"  --no-narrow-regs      keep int32/uint32 locals and arguments on the stack (no 32-bit registers)")
	println(c"  --no-direct-calls     call known functions through the accumulator, not `call rel32`")
	println(c"  --no-addr-modes       address every load and store through the accumulator, no [base+index*scale+disp] operands")
	println(c"  --no-expr-regs        park every waiting operand on the stack, not in a scratch register; -O0 too")
	println(c"  --no-x86-budget       x86-32: no loop registers in ecx/edx (the pre-A9 register budget)")
	println(c"  --inline              emit small leaf callees' bodies in place of their calls (tiny")
	println(c"                        leaves always are; larger for profile-hot sites under --profile-use)")
	println(c"  --no-inline           never emit a callee's body in place of a call")
	println(c"  --wasm-acc=globals|locals  wasm accumulator representation (default: locals)")
	println(c"  --ptx=<path>          dump the embedded PTX module to <path> (gpu kernels)")
	println(c"  --cubin-file=<path>   embed a ptxas-built cubin of that PTX; loaded before the PTX")
	println(c"  --import-root <dir>   search <dir> for imports before the default search;")
	println(c"                        repeatable, earlier roots win (also --import-root=<dir>)")
	println(c"  -v, --verbose         raise verbosity (repeat for compiler debug traces)")
	println(c"  -h, --help            print this help and exit")


void help_selectors():
	println(c"target selectors (default: 32-bit x86 Linux ELF; may appear before")
	println(c"the subcommand word or anywhere before the first input file):")
	println(c"  x64           64-bit x86-64 Linux ELF")
	println(c"  arm64         64-bit AArch64 Linux ELF")
	println(c"  arm64_darwin  64-bit AArch64 macOS Mach-O (self-signed)")
	println(c"  arm64_ios     64-bit AArch64 iOS Mach-O (requires app signing)")
	println(c"  arm64_ios_sim 64-bit AArch64 iOS Simulator Mach-O")
	println(c"  win64         64-bit x86-64 Windows PE")
	println(c"  wasm          32-bit wasm32 + WASI module")


void help_link():
	println(c"usage: w [x64|arm64|arm64_darwin|arm64_ios|arm64_ios_sim|win64|wasm] <file.w>... [-o output] [--bounds=on|off|trap] [--pac=off|ret|full] [--strict] [--quiet] [-v|--verbose] [--version]")
	println(c"")
	println(c"Compile W source files into a native executable. Without -o the")
	println(c"executable bytes are written to stdout.")
	println(c"")
	println(c"subcommands (run 'w <subcommand> --help' for their flags):")
	println(c"  check         compile-only diagnostics; writes no executable")
	println(c"  deps          print the transitive import closure")
	println(c"  symbols       dump global symbols and user-declared types")
	println(c"  defhash       per-definition content hashes and refs (NDJSON)")
	println(c"  tree          inspect owned module trees and semantic identities (NDJSON)")
	println(c"")
	help_selectors()
	println(c"")
	println(c"options:")
	help_shared_options()
	println(c"  --version             print the compiler version and exit")
	println(c"")
	println(c"debugger: 'w --debug <file.w> [args...]' compiles and runs the file")
	println(c"under the in-process debugger, wdbg (see debugger/wdbg.w).")


void help_check():
	println(c"usage: w check [--json] [--quiet] [--all-errors] [--imports] [--bool-ops] [--lint] [--fix] [--line-length=N] [-v|--verbose] [x64|arm64|arm64_darwin|arm64_ios|arm64_ios_sim|win64|wasm] <file.w>... [--bounds=on|off|trap] [--pac=off|ret|full] [--strict]")
	println(c"")
	println(c"Compile without writing an executable. Diagnostics go to stderr; with")
	println(c"--json each becomes one NDJSON record on stdout. Empty output with")
	println(c"exit status 0 means the file is clean.")
	println(c"")
	println(c"options:")
	println(c"  --json                emit NDJSON diagnostic records on stdout")
	println(c"  --all-errors          recover at each statement and keep checking")
	println(c"  --imports             warn when an identifier resolves through a")
	println(c"                        transitive import the file does not import directly")
	println(c"  --bool-ops            also warn on '&'/'|' operands containing calls,")
	println(c"                        where '&&'/'||' short-circuiting would skip them")
	println(c"  --lint                run the lint rules on the named files (unused locals,")
	println(c"                        unreachable code, shadowing, whitespace, ...);")
	println(c"                        'nolint' on a line silences it")
	println(c"  --line-length=N       --lint's line width limit in columns, tabs")
	println(c"                        counted as 4 (default 120; 0 turns it off)")
	println(c"  --fix                 rewrite the named files' fixable whitespace issues in")
	println(c"                        place (indentation, trailing space, blank lines, CRLF,")
	println(c"                        final newline) before checking them")
	help_shared_options()
	println(c"")
	help_selectors()


void help_deps():
	println(c"usage: w deps [--json] [x64|arm64|arm64_darwin|arm64_ios|arm64_ios_sim|win64|wasm] <file.w>... [--bounds=on|off|trap] [--pac=off|ret|full] [--strict]")
	println(c"")
	println(c"Compile like 'w check', then print the path of every file in the")
	println(c"program's transitive import closure (the root, every import, and the")
	println(c"auto-imported runtime), one per line, deduplicated, in first-open")
	println(c"order. Paths under the invocation directory print relative to it.")
	println(c"")
	println(c"options:")
	println(c"  --json                emit one NDJSON record per file on stdout")
	help_shared_options()
	println(c"")
	help_selectors()


void help_symbols():
	println(c"usage: w symbols [--json] [--layout] [x64|arm64|arm64_darwin|arm64_ios|arm64_ios_sim|win64|wasm] <file.w>... [--bounds=on|off|trap] [--pac=off|ret|full] [--strict]")
	println(c"")
	println(c"Compile like 'w check', then dump the global symbol table and the")
	println(c"user-declared types with their declaration locations.")
	println(c"")
	println(c"options:")
	println(c"  --json                emit one NDJSON record per entry on stdout")
	println(c"                        (default: human-readable file:line:column lines)")
	println(c"  --layout              struct layout view: only struct/union records,")
	println(c"                        each with its total size and per-field byte")
	println(c"                        offset/size for the selected target. Offsets are")
	println(c"                        the compiler's packed layout (no native alignment")
	println(c"                        padding; union fields sit at 0); c_import types")
	println(c"                        carry real C ABI padding as explicit __ci_* filler")
	println(c"                        fields and print with the <c_import> file marker")
	help_shared_options()
	println(c"")
	help_selectors()


void help_defhash():
	println(c"usage: w defhash [--closure] [x64|arm64|arm64_darwin|arm64_ios|arm64_ios_sim|win64|wasm] <file.w>... [--bounds=on|off|trap] [--pac=off|ret|full] [--strict]")
	println(c"")
	println(c"Compile like 'w check', then print one NDJSON record per top-level")
	println(c"definition declared in the root file(s): file, name, kind, a sha256")
	println(c"over the definition's own token stream, and the referenced names.")
	println(c"")
	println(c"options:")
	println(c"  --closure             record every definition in the whole program,")
	println(c"                        not just the command-line root file(s)")
	help_shared_options()
	println(c"")
	help_selectors()


# 1 when the argument spells a help request; shared by every argument
# scanner so 'w --help', 'w check -h' and a --help anywhere in a compile
# argument list all work.
int arg_is_help(char* arg):
	if (strcmp(arg, c"--help") == 0): return 1
	if (strcmp(arg, c"-h") == 0): return 1
	return 0


# A dash-prefixed argument no flag branch recognizes is a typo or an
# unsupported option, never an input file; fail fast with the option
# text. Under --json ('w check --json f.w --nope') the failure is a
# proper NDJSON record mirroring the diagnostic shape, so an agent
# parsing the stream sees it instead of bare stderr; the option is not
# in any source file, so file is the fixed "<command-line>" marker and
# line/column are 0.
# P1.4: --streaming named together with an option that only exists on the
# AST front end (or a retaining query, reported as --ast-retain).
void streaming_conflict_error(char* arg):
	diag_part(c"'--streaming' cannot be combined with '")
	diag_part(arg)
	diag_part(c"'")
	if (diag_json): diag_emit(c"error", c"<command-line>", 0, 0, arg)
	else:
		print_error(c"error: ")
		print_error(str_from_cstr(diag_buffer))
		print_error(c"\x0a")
	exit(1)


void unrecognized_option_error(char* arg):
	diag_part(c"unrecognized option: '")
	diag_part(arg)
	diag_part(c"'")
	if (diag_json): diag_emit(c"error", c"<command-line>", 0, 0, arg)
	else:
		print_error(c"error: ")
		print_error(str_from_cstr(diag_buffer))
		print_error(c"\x0a")
	exit(1)


void target_option_error(char* message):
	# Target validation precedes tokenizer/source initialization.
	diag_part(message)
	if (diag_json): diag_emit(c"error", c"<command-line>", 0, 0, c"")
	else:
		print_error(c"error: ")
		print_error(str_from_cstr(diag_buffer))
		print_error(c"\x0a")
	exit(1)


# The on-demand runtimes a compiled program used -- to_json/from_json,
# f"..." template strings, the prelude and var -- imported after all
# user files so the modules' code lands at a top-level boundary, with
# the queued generic instantiations drained first (instantiated bodies
# can rely on the runtimes) and again after (covering instantiations
# the runtime modules might request).
void finish_on_demand_imports():
	generic_finish_instantiations()
	json_codec_finish_import()
	template_string_finish_import()
	prelude_finish_import()
	var_finish_import()
	generic_finish_instantiations()


int link_impl(int argc, int argv, int start_index, int check_mode):
	code_fixed = 0
	code_fixed_error_hook = 0
	if (argc <= start_index):
		println2(c"usage: w [x64|arm64|arm64_darwin|arm64_ios|arm64_ios_sim|win64|wasm] <file.w>... [-o output] [--bounds=on|off|trap] [--pac=off|ret|full] [--strict] [--quiet] [-v|--verbose] [--version]")
		println2(c"run 'w --help' for details")
		exit(1)
	int i = start_index
	word_size = 4
	word_size_log2 = 2
	diag_word_size = word_size
	target_isa = 0
	target_os = 0
	target_apple_platform = 1
	# W^X (docs/projects/wx_split.md Stage C): every file target now
	# splits read-execute text from read-write data, the default x86
	# target included. The in-process REPL and wdbg never come through
	# this reset (they compile into their own RWX mmap buffer), so
	# data_split stays 0 on their paths.
	data_split = 1
	elf_pie = 0
	elf_shared = 0
	elf_static = 0
	static_address_count = 0
	wasm_export_count = 0
	x64_syscall_abi = 0
	x64_hypercall_count = 0
	arm64_pac = 1
	bounds_mode = 1
	strict_mode = 0
	warning_count = 0
	type_error_count = 0
	analysis_mode = 0
	analysis_errors = 0
	retained_clear()
	ast_retain_mode = retained_query_mode
	# P1.4: every compile takes the AST front end unless --streaming.
	ast_expressions_mode = 2
	ast_expressions_emitted = 0
	ast_simple_statements_emitted = 0
	ast_debugger_statements_emitted = 0
	ast_return_statements_emitted = 0
	ast_yield_statements_emitted = 0
	ast_expression_statements_emitted = 0
	ast_goto_statements_emitted = 0
	ast_raw_statements_emitted = 0
	ast_constants_folded = 0
	ast_declarations_emitted = 0
	ast_guards_emitted = 0
	ast_switch_values_emitted = 0
	ast_switch_cases_emitted = 0
	ast_range_loops_emitted = 0
	ast_cursor_loops_emitted = 0
	ast_iteration_values_emitted = 0
	ast_if_regions_emitted = 0
	ast_switch_regions_emitted = 0
	ast_blocks_emitted = 0
	ast_while_loops_emitted = 0
	ast_deferred_expressions_emitted = 0
	ast_extern_objects_emitted = 0
	ast_extern_functions_emitted = 0
	ast_enum_values_emitted = 0
	ast_functions_emitted = 0
	ast_scripts_emitted = 0
	ast_generators_emitted = 0
	ast_kernels_emitted = 0
	ast_kernel_parameters_emitted = 0
	ast_globals_emitted = 0
	ast_global_initializers_emitted = 0
	ast_thread_locals_emitted = 0
	ast_gpu_launches_emitted = 0
	ast_gpu_fors_emitted = 0
	ast_gpu_values_emitted = 0
	ast_gpu_captures_emitted = 0
	ast_roots_emitted = 0
	ast_roots_fallback = 0
	# P1.1: AST probe parse-cost counters (slabs persist across compiles).
	ast_preflight_bytes = 0
	ast_tokenizer_snapshots = 0
	ast_tokens_replayed = 0
	ast_relex_replays = 0
	ast_audit_mode = 0
	ast_required_mode = 0
	# S2.1: retained-forest expression emission and its --stats counter.
	# S2.5: every compile emits from the retained forest, so it retains
	# one; --streaming turns both off below.
	ast_emit_retained_mode = 1
	ast_retain_mode = 1
	ast_retained_emitted = 0
	# P1.2b: semantic snapshot records only for a tree query (or an
	# explicit --ast-retain, link_option).
	retained_semantic_mode = retained_query_mode
	# S2.2a: retained statement walks and their --stats counter.
	ast_retained_statements_emitted = 0
	retained_walks_used = 0
	retained_walk_phases_used = 0
	retained_emit_points_used = 0
	# S2.3: generic/defer instantiation --stats counters.
	generic_source_seeks = 0
	defer_source_seeks = 0
	defer_tree_captures = 0
	defer_tree_emissions = 0
	defer_reparse_exits = 0
	generic_tree_types = 0
	retained_source_reparses = 0
	retained_source_end_positions = 0
	retained_source_reparse_reset()
	# C3.5: the optimizer pass is off unless --ast-opt.
	ast_opt_reset()
	# check/deps/symbols discard the output, so a library module without
	# a _main is fine to analyze: the backend finishers skip the
	# entry-call patch instead of erroring (code_generator/code_emitter.w)
	entry_optional = check_mode
	if (target_pending != 0):
		# Selector spelled before the subcommand word, recorded by
		# main(); a positional selector after the subcommand may still
		# follow and wins.
		target_selector_apply(target_pending)
		target_pending = 0
	# The target selector may appear anywhere before the first input
	# file, so a leading flag does not turn the selector into a
	# filename ('w --strict x64 f.w' used to fail with "no such file:
	# 'x64'"): scan past flags (and -o's consumed argument) to the
	# first positional word, and when that word is a selector apply it
	# now — be_start below bakes the word size in — remembering its
	# index so the positional loop skips it.
	# argv strides by the HOST pointer size: __word_size__ was baked in
	# when this compiler binary was itself compiled
	int selector_index = 0 - 1
	int sel_scan = i
	int sel_scanning = 1
	while (sel_scanning && (sel_scan < argc)):
		char** sel_arg = argv + sel_scan * __word_size__
		if (strcmp(*sel_arg, c"-o") == 0): sel_scan = sel_scan + 2
		else if (import_root_arg_width(*sel_arg) == 2): sel_scan = sel_scan + 2
		else if (starts_with(*sel_arg, c"-")): sel_scan = sel_scan + 1
		else:
			sel_scanning = 0
			if (target_selector_apply(*sel_arg)): selector_index = sel_scan
	if (selector_index == i):
		i = i + 1
		selector_index = 0 - 1
	# --pac is whole-program: signing at materialization and authenticating
	# at the call site must agree across every compiled file (a mixed image
	# would trap at runtime), and the Mach-O header consumes the level in
	# be_start below. --wasm-acc is whole-program too (every wasm function
	# body and call site must agree on the accumulator representation, and
	# be_start below emits the entry/OS stubs). So both levels are fixed by
	# a pre-scan of the remaining arguments here; link_option only
	# recognizes them. --wasm-acc default: locals — the stage-5
	# measurement showed engines run them ~13% faster than module globals
	# for ~4% larger modules (docs/projects/wasm_backend.md).
	wasm_acc_locals = 1
	for pre_scan in range(i, argc):
		char** pre_arg = argv + pre_scan * __word_size__
		if (strcmp(*pre_arg, c"--pac=off") == 0): arm64_pac = 0
		else if (strcmp(*pre_arg, c"--pac=ret") == 0): arm64_pac = 1
		else if (strcmp(*pre_arg, c"--pac=full") == 0): arm64_pac = 2
		else if (strcmp(*pre_arg, c"--wasm-acc=globals") == 0): wasm_acc_locals = 0
		else if (strcmp(*pre_arg, c"--wasm-acc=locals") == 0): wasm_acc_locals = 1
	# Option validation is up front, not positional: a typo'd flag after
	# the file list used to be reported only after every earlier root had
	# fully compiled (docs/projects/ai_tooling.md). -v/--verbose applies
	# here too, so the flag covers the whole compile wherever it appears
	# on the line.
	int flag_scan = i
	int streaming_flag = 0
	char* ast_only_flag = 0
	while (flag_scan < argc):
		char** flag_arg = argv + flag_scan * __word_size__
		if (strcmp(*flag_arg, c"-o") == 0):
			# -o consumes the next argument: an output path may start
			# with '-' without being an option
			flag_scan = flag_scan + 1
		else if (import_root_arg_width(*flag_arg) == 2):
			# so does the separate-value --import-root spelling
			flag_scan = flag_scan + 1
		else if ((strcmp(*flag_arg, c"-v") == 0) || (strcmp(*flag_arg, c"--verbose") == 0)):
			verbosity_raise()
		else if (arg_is_help(*flag_arg)):
			help_link()
			exit(0)
		else if (strcmp(*flag_arg, c"--pie") == 0): elf_pie = 1
		else if (strcmp(*flag_arg, c"--static") == 0):
			elf_static = 1
			elf_pie = 1
		else if (strcmp(*flag_arg, c"--shared") == 0):
			elf_shared = 1
			elf_pie = 1
		else if (strcmp(*flag_arg, c"--syscall-abi=vmcall") == 0): x64_syscall_abi = 1
		else if (strcmp(*flag_arg, c"--syscall-abi=linux") == 0): x64_syscall_abi = 0
		else if (starts_with(*flag_arg, c"-")):
			if (link_option(*flag_arg, 0) == 0): unrecognized_option_error(*flag_arg)
			# Full-expression migration flags cover the implicit runtime
			# closure as well as explicit inputs. Never hide that gap.
			if ((strcmp(*flag_arg, c"--ast-full-expressions") == 0) || (strcmp(*flag_arg, c"--ast-audit") == 0) || (strcmp(*flag_arg, c"--ast-required") == 0) || (strcmp(*flag_arg, c"--ast-retain") == 0)):
				link_option(*flag_arg, 1)
				ast_only_flag = *flag_arg
			# S2.1: so does emission from the retained forest.
			if (strcmp(*flag_arg, c"--ast-emit-retained") == 0):
				link_option(*flag_arg, 1)
				ast_only_flag = *flag_arg
			if (strcmp(*flag_arg, c"--streaming") == 0): streaming_flag = 1
			# C3.5: so does the optimizer pass, an AST-only mode.
			if (strcmp(*flag_arg, c"--ast-opt") == 0):
				link_option(*flag_arg, 1)
				ast_only_flag = *flag_arg
			# --no-asm covers the runtime and every input, whatever its position
			if (strcmp(*flag_arg, c"--no-asm") == 0): link_option(*flag_arg, 1)
			# Register promotion is whole-program too: the auto-imported
			# runtime compiles before the positional loop below
			if ((strcmp(*flag_arg, c"--no-regs") == 0) || (strcmp(*flag_arg, c"-O0") == 0) || (strcmp(*flag_arg, c"--regs") == 0)):
				link_option(*flag_arg, 1)
			if (strcmp(*flag_arg, c"--no-direct-calls") == 0): link_option(*flag_arg, 1)
			if (strcmp(*flag_arg, c"--no-addr-modes") == 0): link_option(*flag_arg, 1)
			if ((strcmp(*flag_arg, c"--no-expr-regs") == 0) || (strcmp(*flag_arg, c"--expr-regs") == 0)):
				link_option(*flag_arg, 1)
			if ((strcmp(*flag_arg, c"--no-x86-budget") == 0) || (strcmp(*flag_arg, c"--x86-budget") == 0)):
				link_option(*flag_arg, 1)
			if ((strcmp(*flag_arg, c"--no-cond-branch") == 0) || (strcmp(*flag_arg, c"--cond-branch") == 0)):
				link_option(*flag_arg, 1)
			if ((strcmp(*flag_arg, c"--no-loop-rotate") == 0) || (strcmp(*flag_arg, c"--loop-rotate") == 0)):
				link_option(*flag_arg, 1)
			if ((strcmp(*flag_arg, c"--no-ivopts") == 0) || (strcmp(*flag_arg, c"--ivopts") == 0)):
				link_option(*flag_arg, 1)
			if ((strcmp(*flag_arg, c"--no-narrow-regs") == 0) || (strcmp(*flag_arg, c"--narrow-regs") == 0)):
				link_option(*flag_arg, 1)
			if ((strcmp(*flag_arg, c"--inline") == 0) || (strcmp(*flag_arg, c"--no-inline") == 0)): link_option(*flag_arg, 1)
			# P1: counters cover the runtime closure too (profile_counters.w).
			if ((strcmp(*flag_arg, c"--profile-generate") == 0) || (strcmp(*flag_arg, c"--coverage") == 0)): link_option(*flag_arg, 1)
			# P2: so does the profile the optimizer reads (profile_use.w).
			if (starts_with(*flag_arg, c"--profile-use=")): link_option(*flag_arg, 1)
		flag_scan = flag_scan + 1
	# P1.4: --streaming selects the streaming front end for every root and
	# the implicit runtime closure. The AST-only modes (and the retaining
	# tree query) have no streaming meaning; check --all-errors recovers in
	# process on either front end (C3.1).
	if (streaming_flag):
		# S2.5: retention is the default, so only a retaining query
		# conflicts here without an explicit flag.
		if (retained_query_mode && (ast_only_flag == 0)): ast_only_flag = c"--ast-retain"
		if (ast_only_flag != 0): streaming_conflict_error(ast_only_flag)
		ast_expressions_mode = 0
		ast_retain_mode = 0
		ast_emit_retained_mode = 0
	# --import-root is whole-program: the roots must be known before the
	# auto-imported container runtime below resolves its first import
	if (elf_shared && elf_static): target_option_error(c"--shared and --static are mutually exclusive")
	if (elf_static && ((word_size != 8) || (target_isa != 0) || (target_os != 0))):
		target_option_error(c"--static requires the x64 Linux target")
	if (elf_static && profile_generate_mode): target_option_error(c"--static does not support profiling instrumentation")
	if (elf_shared && ((word_size != 8) || (target_isa != 0) || (target_os != 0))):
		target_option_error(c"--shared requires the x64 Linux target")
	if (elf_pie && ((word_size != 8) || (target_isa != 0) || (target_os != 0))):
		target_option_error(c"--pie requires the x64 Linux target")
	if (x64_syscall_abi && (word_size != 8 || target_isa != 0 || target_os != 0 || elf_pie)):
		target_option_error(c"--syscall-abi=vmcall requires static non-PIE x64 Linux")
	import_roots_scan(argc, argv)
	push_basic_types()
	pointer_indirection = 0
	# No function body is being compiled yet: the '?' operator checks
	# this to reject uses outside a function.
	current_function_symbol = -1
	last_identifier = cast(char*, malloc(8000))
	last_global_declaration = cast(char*, malloc(8000))
	be_start(word_size)
	static_link_init()
	# Link arguments are registered before extern declarations, irrespective of order.
	for link_scan in range(i, argc):
		char** link_arg = argv + link_scan * __word_size__
		if (strcmp(*link_arg, c"-o") == 0):
			link_scan = link_scan + 1
		else if (import_root_arg_width(*link_arg) == 2):
			link_scan = link_scan + 1
		else if (starts_with(*link_arg, c"--link=")):
			if ((*link_arg)[7] == 0): target_option_error(c"--link requires a library path")
			if (static_link_load(*link_arg + 7) == 0): dyn_add_lib(*link_arg + 7)
	# --imports must never fire while the auto-imported closure itself is
	# compiling: auto_import_closure_count (the exclusion list) is not
	# populated until these two calls return, so a warning fired during
	# them would wrongly scrutinize the closure's own internal transitive
	# reliance (structures/hash_table.w and friends lean on each other's
	# re-exports by design; that is compiler-internal plumbing, not a
	# user file --imports is meant to audit). --bool-ops stays quiet here
	# too: the closure compiles into every program, and its remaining
	# '&'/'|' sites (lib/memory_freelist.w, lib/stack_trace.w, ...) are
	# deliberate call-containing joins the wave-2 sweep left in place —
	# reporting them would spam every --bool-ops check of an unrelated
	# file with sites that file's author cannot fix. The unconditional
	# default hint (operand_is_bool_condition/operand_is_pure) needs no
	# such guard: every call-free site in the closure was already
	# converted, so it has nothing left to warn about here. Suppress
	# --bool-ops's extra reporting, then restore.
	int import_check_saved = check_imports_mode
	int bool_ops_check_saved = check_bool_ops_mode
	check_imports_mode = 0
	check_bool_ops_mode = 0
	import_module(c"structures.hash_table")
	import_module(c"structures.w_list")
	# P1: the counter flush runtime, only under --profile-generate.
	if (profile_generate_mode): profile_import_runtime()
	check_imports_mode = import_check_saved
	check_bool_ops_mode = bool_ops_check_saved
	# Everything registered so far (hash_table, w_list, and whatever they
	# transitively import: lib/memory.w, lib/stack_trace.w, ...) is the
	# auto-imported container-runtime closure that --imports treats like
	# a direct import for every file (grammar/import_statement.w).
	auto_import_closure_count = imported_count
	analysis_mode = analysis_requested

	output_fd = 1 /* default: write the ELF to stdout */
	char* output_path = 0

	while (i < argc):
		char** arg = argv + i * __word_size__
		if (i == selector_index):
			# The target-selector pre-scan above already applied this
			# word; it is not an input file.
			selector_index = 0 - 1
		else if (strcmp(*arg, c"-o") == 0):
			i = i + 1
			asserts(c"-o requires an output path", i < argc)
			arg = argv + i * __word_size__
			output_path = *arg
		else if (import_root_arg_width(*arg) == 2):
			# Applied by import_roots_scan; skip the directory argument
			i = i + 1
		else if (starts_with(*arg, c"-")):
			# Options apply positionally (link_option). A dash-prefixed
			# argument that is not one is a typo or an unsupported
			# option ('--bounds=xyz', '--nope'), not an input file — a
			# file named '-x' is vanishingly rare in this codebase, and
			# treating it as a root instead produced a misleading "no
			# such file: '--bounds=xyz'" (the fallthrough below tried to
			# open it). Normally unreachable: the pre-scan above already
			# failed before any root compiled; kept as a safety net.
			if (link_option(*arg, 1) == 0): unrecognized_option_error(*arg)
		else:
			char* input = *arg
			int lint_text_done = 0
			# A compiler-internal root cannot be checked standalone;
			# check w.w in its place (rule: root_is_compiler_internal)
			if (check_mode && root_is_compiler_internal(input)):
				if (quiet_mode == 0):
					print_error(c"check: ")
					print_error(input)
					print_error(c" is compiler-internal; checking w.w\x0a")
				# --lint/--fix still cover the named file, not w.w
				if (lint_mode || lint_fix_mode):
					lint_quiet = quiet_mode
					lint_text_file(input)
					lint_note_internal_root(input)
					lint_skip_root_open = 1
					lint_text_done = 1
				input = c"w.w"
			# Roots dedupe against the import registry in both
			# directions: a root already compiled — as an earlier
			# argument, or inside an earlier root's import closure — is
			# skipped instead of redefining every symbol, and a root
			# compiled here is registered so a later import of it (or a
			# duplicate argument) is skipped by import_module().
			char* canonical = root_canonical(input)
			if (import_lookup(canonical) >= 0):
				if (quiet_mode == 0):
					print_error(c"skipping '")
					print_error(input)
					print_error(c"' (already compiled)\x0a")
				free(canonical)
			else:
				import_register(canonical)
				# --lint/--fix text pass over the raw root (compiler/lint.w);
				# under --fix the root is rewritten before it compiles
				if ((lint_mode || lint_fix_mode) && (lint_text_done == 0)):
					lint_quiet = quiet_mode
					lint_text_file(input)
				if (quiet_mode == 0):
					print_error(c"compiling '")
					print_error(input)
					print_error(c"'\x0a")
				compile_input_file(input)
				lint_skip_root_open = 0
		i = i + 1

	# 'w check' only (a no-op unless check_main armed generic_check_mode;
	# deps/symbols/defhash share check_mode but never arm it): queue a
	# synthetic [int] instantiation for every generic definition nothing
	# instantiated, so the drain below type-checks its body too
	# (grammar/generic.w, generic_check_instantiate_all).
	if (analysis_errors > 0): return 1
	generic_check_instantiate_all()

	# User generic instantiations drain first, outside the --bool-ops
	# suppression below (finish_on_demand_imports' own first drain then
	# finds the queue empty).
	generic_finish_instantiations()
	if (analysis_errors > 0): return 1

	# The on-demand runtimes (finish_on_demand_imports). Like the
	# auto-import closure above, these are compiler-injected modules, so
	# --bool-ops's extra call-containing reporting stays quiet while they
	# compile — their remaining '&'/'|' sites are deliberate
	# (structures/prelude.w and friends), and would otherwise warn on
	# every --bool-ops check of any file regardless of what that file
	# itself contains.
	int bool_ops_finish_saved = check_bool_ops_mode
	check_bool_ops_mode = 0
	finish_on_demand_imports()
	check_bool_ops_mode = bool_ops_finish_saved
	if (analysis_errors > 0): return 1

	# Synthesize __w_test_main for lib/testing.w consumers now that every
	# test_* function is compiled (compiler/test_registry.w, issue #147)
	test_registry_finish()

	# Embed the PTX module behind __w_ptx_module (and honor --ptx=<path>)
	# for programs that declared gpu kernels (code_generator/ptx.w)
	ptx_finish_module()
	ptx_finish_cubin()

	if (type_error_count > 0): return 1

	# --strict: fail before any output is written so no artifact is
	# produced when warnings fired. Warnings were already printed with
	# their usual text; this only adds a summary and the failing exit.
	# str_from_cstr keeps the message printable when this file is compiled
	# by the seed, which does not coerce char* call arguments to string.
	if (strict_mode):
		if (warning_count > 0):
			print_error(str_from_cstr(c"error: "))
			print_error(str_from_cstr(itoa(warning_count)))
			print_error(str_from_cstr(c" warning(s) treated as errors (--strict)\x0a"))
			exit(1)

	if (output_path != 0):
		/* O_WRONLY|O_CREAT|O_TRUNC, mode 0755 so the result is executable */
		output_fd = open(output_path, 577, 493)
		if (output_fd < 0):
			# Name the path and decode the errno instead of a bare
			# assert: ETXTBSY here almost always means an old build of
			# this very output is still running (issue #377;
			# docs/projects/ai_tooling_next_steps.md).
			print_error(c"error: could not open output file '")
			print_error(output_path)
			print_error(c"': ")
			translate_syscall_failure(output_fd)
			exit(1)
		# A device such as -o /dev/null is not a partial executable: never
		# unlink it on a later error (as root that deletes the device, and
		# the next O_CREAT open recreates it as a regular file that other
		# processes' output then lands in).
		if (starts_with(output_path, c"/dev/") == 0): partial_output_path = output_path
	if (check_mode):
		# O_WRONLY only: never create /dev/null as a regular file.
		output_fd = open(c"/dev/null", 1, 0)
		if (output_fd < 0):
			# Windows: /dev/null does not exist; use the NUL device instead
			output_fd = open(c"NUL", 577, 493)
		asserts(c"could not open null device", output_fd >= 0)

	# print_symbol_table(0)
	# type_print_all()
	# The debugging symbols are ELF section headers plus DWARF, and
	# elf_save_section_info patches the section-header offset into the ELF
	# header at fixed positions — bytes that belong to load commands in a
	# Mach-O and to the COFF header in a PE. The ELF (Linux) targets get
	# them in place; the PE writer embeds a stand-in ELF header at the
	# start of .text for them (debug_elf_origin, code_generator/pe_64.w).
	# Mach-O debug info is a later stage.
	# P1: lay out the --profile-generate counter table, hook exit, write the map.
	profile_finish(output_path, check_mode)
	if (elf_shared || elf_static): elf_emit_export_wrappers()
	if (elf_static):
		static_library_write()
		if ((output_path != 0) || check_mode): close(output_fd)
		partial_output_path = 0
		return 0
	# Dependency discovery needs source imports, not a loadable image.
	# Extern-only consumers can be scanned before their libraries exist.
	if (deps_mode == 0):
		if ((target_os == 0) || (target_os == 2)): emit_debugging_symbols(word_size)
		be_finish(word_size)

	if ((output_path != 0) | check_mode): close(output_fd)
	partial_output_path = 0

	# Every subcommand routes through link_impl (link, check_main,
	# deps_main, symbols_main, defhash_main), so one call here covers
	# them all.
	if (stats_mode): sym_stats_dump()
	if (stats_mode): regalloc_stats_dump()
	if (stats_mode): inline_stats_dump()
	if (stats_mode): profile_use_stats_dump()   # P2: --profile-use
	if (stats_mode && ast_retain_mode):
		print_int0(c"Retained AST nodes: ", retained_node_count())
		print_error(c"\n")
		# P1.2b: expression operands among them, and the session arena.
		print_int0(c"Retained expression operands: ", retained_operand_total)
		print_error(c"\nRetained text bytes: ")
		print_error(itoa(retained_text_total))
		print_error(c"\nRetained arena bytes: ")
		print_error(itoa(retained_arena_used()))
		print_error(c"\n")
	if (stats_mode && ast_expressions_mode):
		print_error(c"AST expressions: ")
		print_error(itoa(ast_expressions_emitted))
		print_error(c"\n")

	if (stats_mode && (ast_expressions_mode >= 2)):
		print_error(c"AST simple statements: ")
		print_error(itoa(ast_simple_statements_emitted))
		print_error(c"\nAST debugger statements: ")
		print_error(itoa(ast_debugger_statements_emitted))
		print_error(c"\n")
		print_error(c"AST return statements: ")
		print_error(itoa(ast_return_statements_emitted))
		print_error(c"\nAST yield statements: ")
		print_error(itoa(ast_yield_statements_emitted))
		print_error(c"\n")
		print_error(c"AST expression statements: ")
		print_error(itoa(ast_expression_statements_emitted))
		print_error(c"\n")
		print_error(c"AST goto/label statements: ")
		print_error(itoa(ast_goto_statements_emitted))
		print_error(c"\n")
		print_error(c"AST extern objects: ")
		print_error(itoa(ast_extern_objects_emitted))
		print_error(c"\nAST extern functions: ")
		print_error(itoa(ast_extern_functions_emitted))
		print_error(c"\nAST enum values: ")
		print_error(itoa(ast_enum_values_emitted))
		print_error(c"\n")
		print_error(c"AST functions: ")
		print_error(itoa(ast_functions_emitted))
		print_error(c"\nAST scripts: ")
		print_error(itoa(ast_scripts_emitted))
		print_error(c"\nAST generators: ")
		print_error(itoa(ast_generators_emitted))
		print_error(c"\nAST kernels: ")
		print_error(itoa(ast_kernels_emitted))
		print_error(c"\nAST kernel parameters: ")
		print_error(itoa(ast_kernel_parameters_emitted))
		print_error(c"\n")
		print_error(c"AST globals: ")
		print_error(itoa(ast_globals_emitted))
		print_error(c"\nAST global initializers: ")
		print_error(itoa(ast_global_initializers_emitted))
		print_error(c"\nAST thread locals: ")
		print_error(itoa(ast_thread_locals_emitted))
		print_error(c"\n")
		print_error(c"AST GPU launches: ")
		print_error(itoa(ast_gpu_launches_emitted))
		print_error(c"\n")
		print_error(c"AST GPU loops: ")
		print_error(itoa(ast_gpu_fors_emitted))
		print_error(c"\n")
		print_error(c"AST GPU header values: ")
		print_error(itoa(ast_gpu_values_emitted))
		print_error(c"\n")
		print_error(c"AST GPU captures: ")
		print_error(itoa(ast_gpu_captures_emitted))
		print_error(c"\n")
		print_error(c"AST deferred expressions: ")
		print_error(itoa(ast_deferred_expressions_emitted))
		print_error(c"\n")
		print_error(c"AST if regions: ")
		print_error(itoa(ast_if_regions_emitted))
		print_error(c"\n")
		print_error(c"AST switch regions: ")
		print_error(itoa(ast_switch_regions_emitted))
		print_error(c"\n")
		print_error(c"AST blocks: ")
		print_error(itoa(ast_blocks_emitted))
		print_error(c"\n")
		print_error(c"AST while loops: ")
		print_error(itoa(ast_while_loops_emitted))
		print_error(c"\n")
		print_error(c"AST range loops: ")
		print_error(itoa(ast_range_loops_emitted))
		print_error(c"\n")
		print_error(c"AST cursor loops: ")
		print_error(itoa(ast_cursor_loops_emitted))
		print_error(c"\n")
		print_error(c"AST iteration values: ")
		print_error(itoa(ast_iteration_values_emitted))
		print_error(c"\n")
		print_error(c"AST switch selectors: ")
		print_error(itoa(ast_switch_values_emitted))
		print_error(c"\nAST switch case values: ")
		print_error(itoa(ast_switch_cases_emitted))
		print_error(c"\n")
		print_error(c"AST conditional branches: ")
		print_error(itoa(ast_guards_emitted))
		print_error(c"\n")
		print_error(c"AST local declarations: ")
		print_error(itoa(ast_declarations_emitted))
		print_error(c"\n")
		print_error(c"AST constant expressions: ")
		print_error(itoa(ast_constants_folded))
		print_error(c"\n")
		print_error(c"AST raw-asm statements: ")
		print_error(itoa(ast_raw_statements_emitted))
		print_error(c"\n")
		print_error(c"AST expression roots: ")
		print_error(itoa(ast_roots_emitted))
		print_error(c"\nStreaming expression roots: ")
		print_error(itoa(ast_roots_fallback))
		print_error(c"\n")
		# P1.1: AST probe parse-cost counters.
		print_error(c"AST preflight bytes: ")
		print_error(itoa(ast_preflight_bytes))
		print_error(c"\nAST tokenizer snapshots: ")
		print_error(itoa(ast_tokenizer_snapshots))
		print_error(c"\nAST tokens replayed: ")
		print_error(itoa(ast_tokens_replayed))
		print_error(c"\nAST relexed roots: ")
		print_error(itoa(ast_relex_replays))
		print_error(c"\nAST node slabs: ")
		print_error(itoa(ast_slabs_allocated))
		print_error(c"\n")
	# S2.1: retained-forest expression emission.
	if (stats_mode && ast_emit_retained_mode):
		print_error(c"Retained-emitted expressions: ")
		print_error(itoa(ast_retained_emitted))
		print_error(c"\n")
	# S2.2a: statements emitted by the retained walk, and the rest, which
	# were emitted during their parse.
	if (stats_mode && ast_emit_retained_mode):
		print_error(c"Retained-emitted statements: ")
		print_error(itoa(ast_retained_statements_emitted))
		print_error(c"\nImmediate statements: ")
		print_error(itoa(retained_statement_count() - ast_retained_statements_emitted))
		print_error(c"\n")
	# S2.3: generic instantiations and deferred-statement replays that
	# reopened and seeked a source file, and what replaced them.
	if (stats_mode):
		print_error(c"Generic instantiation source seeks: ")
		print_error(itoa(generic_source_seeks))
		print_error(c"\nDeferred statement source seeks: ")
		print_error(itoa(defer_source_seeks))
		print_error(c"\nDeferred syntax trees captured: ")
		print_error(itoa(defer_tree_captures))
		print_error(c"\nDeferred syntax tree emissions: ")
		print_error(itoa(defer_tree_emissions))
		print_error(c"\nDeferred expression reparses: ")
		print_error(itoa(defer_reparse_exits))
		print_error(c"\n")
	# A7: while loops rotated (grammar/loop_rotate.w), those whose
	# condition skip declined, and condition returns that left the
	# buffered window.
	if (stats_mode):
		print_error(c"Loop rotation: while loops rotated ")
		print_error(itoa(loop_rotate_whiles))
		print_error(c", declined ")
		print_error(itoa(loop_rotate_declined))
		print_error(c", source seeks ")
		print_error(itoa(loop_rotate_seeks))
		print_error(c"\n")
	if (stats_mode && ast_emit_retained_mode):
		print_error(c"Generic types from retained trees: ")
		print_error(itoa(generic_tree_types))
		print_error(c"\nRetained-source reparses: ")
		print_error(itoa(retained_source_reparses))
		print_error(c"\nRetained-source reparses positioned at the file's end: ")
		print_error(itoa(retained_source_end_positions))
		print_error(c"\n")
	# C3.5: what the optimizer pass folded and removed.
	if (stats_mode): ast_opt_stats_dump()


	return 0


int link(int argc, int argv):
	return link_impl(argc, argv, 1, 0)


int check_main(int argc, int argv):
	int i = 2
	analysis_requested = 0
	diag_json = 0
	check_imports_mode = 0
	check_bool_ops_mode = 0
	lint_mode = 0
	lint_fix_mode = 0
	lint_line_limit = 120
	# Type-check uninstantiated generic bodies too (grammar/generic.w,
	# generic_check_instantiate_all): check only, never plain compilation
	generic_check_mode = 1
	# Leading flags in any order; --quiet must be consumed before
	# link_impl sees the argument list so the x64/arm64 mode banner and
	# the per-file banner are suppressed from the start.
	int scanning = 1
	while (scanning & (i < argc)):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--json") == 0):
			diag_json = 1
			i = i + 1
		else if (strcmp(*arg, c"--all-errors") == 0):
			# C3.1: in-process recovery needs the native setjmp/longjmp
			# stubs, which wasm hosts lack.
			if (__target_isa__ == 2):
				println2(c"--all-errors is not supported on wasm hosts")
				return 1
			analysis_requested = 1
			i = i + 1
		else if (strcmp(*arg, c"--quiet") == 0):
			quiet_mode = 1
			i = i + 1
		else if (strcmp(*arg, c"--imports") == 0):
			# Opt-in transitive-import check: warn when an identifier
			# resolves to a symbol defined in a module this file does not
			# import directly (grammar/import_statement.w,
			# import_warn_transitive). Off by default.
			check_imports_mode = 1
			i = i + 1
		else if (strcmp(*arg, c"--bool-ops") == 0):
			# Opt-in superset of the bool-bitwise condition hint: also
			# warn when an operand contains a function call, where
			# '&&'/'||' short-circuiting could skip a call the current
			# '&'/'|' code always executes (grammar/binary_op.w,
			# operand_is_pure). The default hint already fires for
			# call-free bool/comparison operands. Off by default.
			check_bool_ops_mode = 1
			i = i + 1
		else if (strcmp(*arg, c"--lint") == 0):
			# Opt-in lint rules for the command-line roots
			# (compiler/lint.w)
			lint_mode = 1
			i = i + 1
		else if (strcmp(*arg, c"--fix") == 0):
			# Rewrite the roots' fixable text issues in place before
			# checking them (compiler/lint.w, lint_text_file)
			lint_fix_mode = 1
			i = i + 1
		else if (starts_with(*arg, c"--line-length=")):
			lint_line_limit = atoi(*arg + 14)
			i = i + 1
		else if (import_root_arg_width(*arg) > 0):
			# Applied by link_impl's import_roots_scan over all of argv
			i = i + import_root_arg_width(*arg)
		else if ((strcmp(*arg, c"-v") == 0) || (strcmp(*arg, c"--verbose") == 0)):
			# Consumed here (link_impl's own pre-scan would also apply a
			# trailing -v) so 'w check -v --json f.w' keeps scanning the
			# leading flags after it instead of stopping.
			verbosity_raise()
			i = i + 1
		else if (arg_is_help(*arg)):
			help_check()
			exit(0)
		else: scanning = 0
	if (argc <= i):
		println2(c"usage: w check [--json] [--quiet] [--all-errors] [--imports] [--bool-ops] [--lint] [--fix] [--line-length=N] [-v|--verbose] [x64|arm64|arm64_darwin|arm64_ios|arm64_ios_sim|win64|wasm] <file.w>... [--bounds=on|off|trap] [--pac=off|ret|full] [--strict]")
		println2(c"run 'w check --help' for details")
		exit(1)
	return link_impl(argc, argv, i, 1)


/*
w deps [--json] [x64|arm64|arm64_darwin|arm64_ios|arm64_ios_sim|win64] <file.w>...

Compiles like 'w check' (output to /dev/null), then prints the path of
every file in the program's transitive import closure — the root file,
every import, and the auto-imported runtime modules — one per line,
deduplicated, in the order the compiler first opened them. Paths under
the invocation directory are printed relative to it (repo-relative when
run from the repo root); anything else keeps its absolute path. --json
emits one NDJSON record per file ({"file": "..."}), mirroring
'w check --json'. Like 'check', the subcommand composes with the target
selectors — before the file list, or before the subcommand word itself
('w x64 deps f.w') — and resolves lib/__arch__/ imports for the selected
target, so per-arch closures come out right.
*/


# A recorded absolute path as deps prints it: relative to the invocation
# directory when under it, else unchanged. Points into path.
char* deps_display_path(char* path, char* cwd):
	int cwd_len = strlen(cwd)
	if (starts_with(path, cwd)):
		if (path[cwd_len] == '/'): return path + cwd_len + 1
	return path


# shadows (newline-separated absolute paths, or 0): the --import-root
# candidates this file hid, as a "shadows" array in the --json record
# only -- never present without roots, so the default output is
# unchanged.
void deps_emit(int json, char* path, char* shadows, char* cwd):
	if (json):
		diag_write_cstr(c"{")
		diag_write_json_field(c"file", path)
		if (shadows != 0):
			diag_write_cstr(c", ")
			diag_write_json_string(c"shadows")
			diag_write_cstr(c": [")
			char* rest = strclone(shadows)
			char* item = rest
			int first = 1
			int done = 0
			while (done == 0):
				int k = 0
				while ((item[k] != 0) && (item[k] != 10)): k = k + 1
				if (item[k] == 0): done = 1
				item[k] = 0
				if (first == 0): diag_write_cstr(c", ")
				diag_write_json_string(deps_display_path(item, cwd))
				first = 0
				item = item + k + 1
			free(rest)
			diag_write_cstr(c"]")
		diag_write_cstr(c"}\x0a")
	else:
		diag_write_cstr(path)
		diag_write_cstr(c"\x0a")
	diag_flush()


void deps_dump(int json):
	int max_path_size = 4096
	char* cwd = cast(char*, malloc(max_path_size))
	getcwd(cwd, max_path_size)
	int i = 0
	while (i < deps_count):
		char* path = cast(char*, load_ptr(deps_paths + i * __word_size__))
		# Deduplicate on the recorded (absolute) path
		int duplicate = 0
		for j in range(i):
			char* seen = cast(char*, load_ptr(deps_paths + j * __word_size__))
			if (strcmp(seen, path) == 0): duplicate = 1
		if (duplicate == 0):
			char* shadows = cast(char*, load_ptr(deps_shadow_lists + i * __word_size__))
			deps_emit(json, deps_display_path(path, cwd), shadows, cwd)
		i = i + 1
	free(cwd)


int deps_main(int argc, int argv):
	int i = 2
	int json = 0
	diag_json = 0
	int scanning = 1
	while (scanning & (i < argc)):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--json") == 0):
			json = 1
			diag_json = 1
			i = i + 1
		else if (import_root_arg_width(*arg) > 0):
			# Applied by link_impl's import_roots_scan over all of argv
			i = i + import_root_arg_width(*arg)
		else if (arg_is_help(*arg)):
			help_deps()
			exit(0)
		else: scanning = 0
	if (argc <= i):
		println2(c"usage: w deps [--json] [x64|arm64|arm64_darwin|arm64_ios|arm64_ios_sim|win64|wasm] <file.w>... [--bounds=on|off|trap] [--pac=off|ret|full] [--strict]")
		println2(c"run 'w deps --help' for details")
		exit(1)
	deps_mode = 1
	link_impl(argc, argv, i, 1)
	deps_dump(json)
	return 0


/*
w defhash [--closure] [x64|arm64|arm64_darwin|arm64_ios|arm64_ios_sim|win64] <file.w>...

Compiles like 'w check' (output to /dev/null), then prints one NDJSON
record per top-level definition (function, global variable, struct,
union, enum, type alias, generic function, generic struct, operator
overload) declared directly in the root file(s) named on the command
line: {"file", "name", "kind", "hash", "refs"}. "hash" is a sha256 over
the definition's own token stream -- kind+text pairs, whitespace and
comments excluded -- so a reformatting or comment-only edit leaves it
unchanged while any real content edit changes it. "refs" lists the OTHER
recorded definitions' names that appear as an identifier token inside
the definition's span (deduplicated, sorted), the approximation of
"symbols this definition depends on" described in
docs/projects/build_system_next.md's 4a.

Scope: by default only definitions declared directly in the command-line
root file(s) are recorded -- not their imports, and not the
auto-imported container-runtime closure every program pulls in. --closure
widens that to every definition in the whole compiled program, matching
'deps' full transitive-closure scope. Root-vs-import scoping is tracked
by defhash_depth (see compile_save below) rather than by comparing
paths: 0 while the tokens just parsed belong directly to a root
argument, >0 while inside an import's own nested compile.

Generic struct/function definitions (wave plan C task 4f): the
scan-ahead/re-parse machinery (grammar/generic.w) that captures a
generic definition's span for later instantiation now also calls
defhash_note over that exact span, so a generic's own definition is
hashed like any other -- an instantiation elsewhere is not itself a
definition and never touches the hash. "name" is the BASE identifier
with no '[T]' (e.g. "max", not "max[T]"), since the definition itself
does not change across instantiations; "kind" is "generic_function" or
"generic_struct" rather than plain "function"/"struct" so a consumer can
tell the two apart (the function/struct namespaces are separate, so a
plain and a generic definition could otherwise share a name and kind).

'operator' overload definitions (wave plan C task 4f): unlike generics,
an overload (grammar/operator_overload.w) is compiled immediately, not
deferred -- there is no separate registry span to reuse, so
operator_definition() instead builds a synthetic "name" once the operand
types are known and defhash_note is called with the ordinary
declaration span (grammar/program.w). Every overload of one operator
SPELLING declares the same real symbol ("operator") before mangling, so
the recorded "name" cannot be that shared string: it is
"operator<spelling>(<left>, <right>)" (e.g. "operator+(vec3, vec3)"),
built from the same operand-type spellings the real mangled symbol name
uses, which keeps it unique within a file for the same reason the
mangled name is. "kind" is "operator". An operator is invoked through
its token (`a + b`), never by referring to this synthetic name, so no
other definition's "refs" list can ever name an operator overload --
not a bug, just a consequence of operators having no callable-by-name
call sites for the token-text ref scan to match.

A struct/union field name or enum constant that happens to share text
with another top-level definition's name is indistinguishable, in this
token-stream scan, from a real reference to it, and so can appear as a
false-positive ref; the scan also does not special-case shadowing (a
parameter or local that reuses another definition's name reads as a
reference to it). "Source order" is the order definitions were recorded
in, which is exactly file-order for the default (single root, no
--closure) case; --closure interleaves recording across files in
compile-visitation order rather than a stable (file, offset) sort.
*/


# defhash_closure_mode/defhash_depth are declared near deps_mode above,
# where compile_save can see them; everything else defhash-specific
# follows here.
char* defhash_names
char* defhash_kinds
char* defhash_file_indexes
char* defhash_lines
char* defhash_columns
char* defhash_starts
char* defhash_ends
int defhash_count

# Name -> 1 existence index mirroring defhash_names, consulted by
# defhash_is_known_definition (below) instead of a linear scan over
# defhash_count. Built-in map[char*, int] is fine here: it is what
# libs/extras/c_import/importer.w's own name-existence checks
# (ci_imported_functions) already use, and that file compiles under the
# same pinned seed as this one (CLAUDE.md's seed-graph list) -- so this
# introduces no new pattern, just applies the codebase's existing
# string-set idiom at compiler-internal scope instead of a leaf library's.
map[char*, int] defhash_name_index


# Called by the grammar's top-level declaration recognizers (struct,
# union, enum and type-alias declarations in their own grammar/*.w
# files; the plain function/global branch in grammar/program.w) once a
# definition's full span is known. A no-op whenever defhash_mode is off,
# so this is safe to call unconditionally -- and every one of those call
# sites does, since 'kind' is only known at the very end of a successful
# parse anyway.
void defhash_note(char* name, char* kind, int file_index, int line, int column, int start_offset, int end_offset):
	retained_declaration_note(name, kind, start_offset, end_offset, line, column)
	if (defhash_mode == 0): return
	if ((defhash_closure_mode == 0) && (defhash_depth != 0)): return
	# P1: --profile-generate records the whole closure (w.w's is ~5.6k).
	int max_defs = 20000
	if (defhash_names == 0):
		defhash_names = cast(char*, malloc(max_defs * __word_size__))
		defhash_kinds = cast(char*, malloc(max_defs * __word_size__))
		defhash_file_indexes = cast(char*, malloc(max_defs * __word_size__))
		defhash_lines = cast(char*, malloc(max_defs * __word_size__))
		defhash_columns = cast(char*, malloc(max_defs * __word_size__))
		defhash_starts = cast(char*, malloc(max_defs * __word_size__))
		defhash_ends = cast(char*, malloc(max_defs * __word_size__))
	assert1(defhash_count < max_defs)
	save_ptr(defhash_names + defhash_count * __word_size__, cast(int, name))
	save_ptr(defhash_kinds + defhash_count * __word_size__, cast(int, kind))
	save_ptr(defhash_file_indexes + defhash_count * __word_size__, file_index)
	save_ptr(defhash_lines + defhash_count * __word_size__, line)
	save_ptr(defhash_columns + defhash_count * __word_size__, column)
	save_ptr(defhash_starts + defhash_count * __word_size__, start_offset)
	save_ptr(defhash_ends + defhash_count * __word_size__, end_offset)
	defhash_count = defhash_count + 1
	if (defhash_name_index == 0): defhash_name_index = new map[char*, int]
	defhash_name_index[name] = 1


# Classification tag for one token's text, used only to keep the hashed
# byte stream unambiguous (defhash_process_span appends "<kind><len>:
# <text>" per token) -- not a full lexical classification. Keywords and
# identifiers deliberately share 'i': the token TEXT already
# distinguishes 'if' from a variable named 'if_ready', and nothing
# downstream needs the finer distinction.
char* defhash_token_kind(char* tok):
	int c0 = tok[0] & 255
	if (c0 == 0): return c"e"
	if (('0' <= c0) && (c0 <= '9')): return c"n"
	if (c0 == '"'): return c"s"
	if (c0 == 39): return c"h"
	if (((c0 == 's') || (c0 == 'c') || (c0 == 'f')) && (tok[1] == '"')): return c"s"
	if (is_ident_start_byte(c0)): return c"i"
	return c"o"


# Dynamic byte buffer accumulating one span's length-prefixed token
# stream before it is fed to sha256() in one shot.
char* defhash_buf
int defhash_buf_size
int defhash_buf_pos


void defhash_buf_reset():
	defhash_buf_pos = 0


void defhash_buf_ensure(int n):
	if (defhash_buf_size == 0):
		defhash_buf_size = 256
		defhash_buf = cast(char*, malloc(defhash_buf_size))
	while (defhash_buf_size <= defhash_buf_pos + n):
		int old_size = defhash_buf_size
		defhash_buf_size = defhash_buf_size << 1
		defhash_buf = realloc(defhash_buf, old_size, defhash_buf_size)


void defhash_buf_append_n(char* s, int len):
	defhash_buf_ensure(len)
	for i in range(len):
		defhash_buf[defhash_buf_pos] = s[i]
		defhash_buf_pos = defhash_buf_pos + 1


void defhash_buf_append(char* s):
	defhash_buf_append_n(s, strlen(s))


# refs accumulator for the definition currently being processed: borrowed
# pointers are never stored here (defhash_refs_add clones), so the
# buffer is reused across definitions by just resetting the count.
char* defhash_refs_buf
int defhash_refs_cap
int defhash_refs_count


void defhash_refs_reset():
	if (defhash_refs_buf == 0):
		defhash_refs_cap = 512
		defhash_refs_buf = cast(char*, malloc(defhash_refs_cap * __word_size__))
	defhash_refs_count = 0


int defhash_refs_contains(char* name):
	int i = 0
	while (i < defhash_refs_count):
		if (strcmp(cast(char*, load_ptr(defhash_refs_buf + i * __word_size__)), name) == 0):
			return 1
		i = i + 1
	return 0


void defhash_refs_add(char* name):
	if (defhash_refs_contains(name)): return
	assert1(defhash_refs_count < defhash_refs_cap)
	save_ptr(defhash_refs_buf + defhash_refs_count * __word_size__, cast(int, strclone(name)))
	defhash_refs_count = defhash_refs_count + 1


# Insertion sort: refs lists are short (a handful of names), so this
# stays cheap and needs no dependency on a generic sort helper.
void defhash_refs_sort():
	int i = 1
	while (i < defhash_refs_count):
		char* key = cast(char*, load_ptr(defhash_refs_buf + i * __word_size__))
		int j = i - 1
		# '&&' is load-bearing here, not just style: with '&' (no
		# short-circuit) the strcmp side would still evaluate at j == -1,
		# reading one slot before defhash_refs_buf.
		while ((j >= 0) && (strcmp(cast(char*, load_ptr(defhash_refs_buf + j * __word_size__)), key) > 0)):
			save_ptr(defhash_refs_buf + (j + 1) * __word_size__, load_ptr(defhash_refs_buf + j * __word_size__))
			j = j - 1
		save_ptr(defhash_refs_buf + (j + 1) * __word_size__, cast(int, key))
		i = i + 1


# 1 when 'name' matches some OTHER recorded definition's name: a
# defhash_name_index lookup (wave plan C task 4f) instead of a linear
# scan over defhash_count. The linear scan stayed well under the cost of
# the tokenizing it runs alongside for this repo's own runs (a single
# file by default, ~360 definitions for the whole lib.lib closure under
# --closure), but a map lookup is O(1) regardless of scale, which matters
# once --closure runs over a program an order of magnitude bigger.
int defhash_is_known_definition(char* name):
	if (defhash_name_index == 0): return 0
	return name in defhash_name_index


# Re-tokenize definition `idx`'s recorded [start, end) byte span, on a
# freshly opened fd seeked to its start offset (mirrors
# grammar/generic.w's generic_reparse_start, minus the outer-state
# save/restore: defhash_dump runs after link_impl has fully finished, so
# nothing downstream reads tokenizer globals again). Leaves
# defhash_buf/defhash_refs_buf holding the span's hashable byte stream
# and reference list.
void defhash_process_span(int idx):
	int file_index = load_ptr(defhash_file_indexes + idx * __word_size__)
	char* path = debug_file_name(file_index)
	int start_offset = load_ptr(defhash_starts + idx * __word_size__)
	int end_offset = load_ptr(defhash_ends + idx * __word_size__)
	char* self_name = cast(char*, load_ptr(defhash_names + idx * __word_size__))

	defhash_buf_reset()
	defhash_refs_reset()

	int f = open(path, 0, 511)
	if (f < 0):
		print_error(c"defhash: cannot reopen '")
		print_error(path)
		print_error(c"' to hash a definition\x0a")
		exit(1)
	getchar_reset(f)
	getchar_seek(f, start_offset)
	file = f
	filename = path
	byte_offset = start_offset
	line_number = 0
	column_number = 0
	tab_level = 0
	token_newline = 0
	nextc = 0
	nextc = get_character()
	defhash_rehash_mode = 1
	get_token()
	int prev_was_dot = 0
	# f"..{expr}.." spans: get_token() alone would read the text after
	# an embedded expression's closing '}' as ordinary tokens (a '"'
	# there opens an unterminated string literal), so track each open
	# template's brace depth and resume its literal chunk with
	# get_token_template_chunk(), exactly as the grammar does.
	int* template_depths = cast(int*, malloc(64 * __word_size__))
	int template_open = 0
	int token_is_chunk = 0
	while ((token[0] != 0) && (token_start_offset < end_offset)):
		char* kind = defhash_token_kind(token)
		defhash_buf_append(kind)
		char* len_digits = itoa(strlen(token))
		defhash_buf_append(len_digits)
		free(len_digits)
		defhash_buf_append(c":")
		defhash_buf_append(token)
		if ((strcmp(kind, c"i") == 0) && (prev_was_dot == 0) && (strcmp(token, self_name) != 0)):
			if (defhash_is_known_definition(token)): defhash_refs_add(token)
		prev_was_dot = strcmp(token, c".") == 0
		int resume_chunk = 0
		if (token_is_chunk): token_is_chunk = 0
		else if ((token[0] == 'f') && (token[1] == '"')):
			if (token[strlen(token) - 1] == '{'):
				if (template_open == 64): error(c"f-string templates nested too deeply")
				template_depths[template_open] = 0
				template_open = template_open + 1
		else if (template_open > 0):
			if (strcmp(token, c"{") == 0): template_depths[template_open - 1] = template_depths[template_open - 1] + 1
			else if (strcmp(token, c"}") == 0):
				if (template_depths[template_open - 1] == 0): resume_chunk = 1
				else: template_depths[template_open - 1] = template_depths[template_open - 1] - 1
		if (resume_chunk):
			get_token_template_chunk()
			# A chunk ending in '{' opens the template's next expression.
			if (token[strlen(token) - 1] != '{'): template_open = template_open - 1
			token_is_chunk = 1
		else: get_token()
	free(cast(void*, template_depths))
	defhash_rehash_mode = 0
	close(f)
	defhash_refs_sort()


char* defhash_hex_digits(char* digest):
	char* hex = cast(char*, malloc(65))
	for i in range(32):
		hex[i * 2] = diag_hex_digit((digest[i] >> 4) & 15)
		hex[i * 2 + 1] = diag_hex_digit(digest[i] & 15)
	hex[64] = 0
	return hex


void defhash_emit(int idx, char* cwd, int cwd_len):
	char* name = cast(char*, load_ptr(defhash_names + idx * __word_size__))
	char* kind = cast(char*, load_ptr(defhash_kinds + idx * __word_size__))
	int file_index = load_ptr(defhash_file_indexes + idx * __word_size__)
	char* path = debug_file_name(file_index)
	char* shown = path
	if (starts_with(path, cwd)):
		if (path[cwd_len] == '/'): shown = path + cwd_len + 1

	defhash_process_span(idx)
	char* digest = cast(char*, malloc(32))
	sha256(defhash_buf, defhash_buf_pos, digest)
	char* hex = defhash_hex_digits(digest)
	free(digest)

	diag_write_cstr(c"{")
	diag_write_json_field(c"file", shown)
	diag_write_cstr(c", ")
	diag_write_json_field(c"name", name)
	diag_write_cstr(c", ")
	diag_write_json_field(c"kind", kind)
	diag_write_cstr(c", ")
	diag_write_json_field(c"hash", hex)
	diag_write_cstr(c", ")
	diag_write_json_string(c"refs")
	diag_write_cstr(c": [")
	int j = 0
	while (j < defhash_refs_count):
		if (j > 0): diag_write_cstr(c", ")
		diag_write_json_string(cast(char*, load_ptr(defhash_refs_buf + j * __word_size__)))
		j = j + 1
	diag_write_cstr(c"]}\x0a")
	diag_flush()
	free(hex)


void defhash_dump():
	int max_path_size = 4096
	char* cwd = cast(char*, malloc(max_path_size))
	getcwd(cwd, max_path_size)
	int cwd_len = strlen(cwd)
	int i = 0
	while (i < defhash_count):
		defhash_emit(i, cwd, cwd_len)
		i = i + 1
	free(cwd)


# --- P1: --profile-generate's map sidecar (code_generator/profile_counters.w)
# keys every counter by the enclosing definition's defhash, the same
# sha256 defhash_emit prints. The option block arms defhash recording,
# so by profile_finish every definition is in the arrays above;
# profile_counters.w (compiled before this file, so it cannot read those
# arrays) asks by the function symbol's declaration file and line, which
# a function/operator/generic_function entry shares with its name token.
map[char*, int] profile_defhash_index


char* profile_defhash_key(int file_index, int line):
	char* file_digits = itoa(file_index)
	char* line_digits = itoa(line)
	char* with_colon = strjoin(file_digits, c":")
	char* key = strjoin(with_colon, line_digits)
	free(file_digits)
	free(line_digits)
	free(with_colon)
	return key


# Index of the recorded function-like definition at file_index:line, or -1.
int profile_defhash_find(int file_index, int line):
	if (profile_defhash_index == 0):
		profile_defhash_index = new map[char*, int]
		int i = 0
		while (i < defhash_count):
			char* kind = cast(char*, load_ptr(defhash_kinds + i * __word_size__))
			if ((strcmp(kind, c"function") == 0) || (strcmp(kind, c"operator") == 0) || (strcmp(kind, c"generic_function") == 0)):
				char* key = profile_defhash_key(load_ptr(defhash_file_indexes + i * __word_size__), load_ptr(defhash_lines + i * __word_size__))
				if ((key in profile_defhash_index) == 0): profile_defhash_index[key] = i
				else: free(key)
			i = i + 1
	char* probe = profile_defhash_key(file_index, line)
	int found = -1
	if (probe in profile_defhash_index): found = profile_defhash_index[probe]
	free(probe)
	return found


# The 64-hex sha256 of definition idx's token stream (malloc'd), exactly
# what defhash_emit prints as "hash".
char* profile_defhash_hex_at(int idx):
	defhash_process_span(idx)
	char* digest = cast(char*, malloc(32))
	sha256(defhash_buf, defhash_buf_pos, digest)
	char* hex = defhash_hex_digits(digest)
	free(digest)
	return hex


char* profile_defhash_name_at(int idx):
	return cast(char*, load_ptr(defhash_names + idx * __word_size__))


int defhash_main(int argc, int argv):
	int i = 2
	defhash_closure_mode = 0
	diag_json = 0
	int scanning = 1
	while (scanning & (i < argc)):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--closure") == 0):
			defhash_closure_mode = 1
			i = i + 1
		else if (import_root_arg_width(*arg) > 0):
			i = i + import_root_arg_width(*arg)
		else if (arg_is_help(*arg)):
			help_defhash()
			exit(0)
		else: scanning = 0
	if (argc <= i):
		println2(c"usage: w defhash [--closure] [x64|arm64|arm64_darwin|arm64_ios|arm64_ios_sim|win64|wasm] <file.w>... [--bounds=on|off|trap] [--pac=off|ret|full] [--strict]")
		println2(c"run 'w defhash --help' for details")
		exit(1)
	defhash_mode = 1
	defhash_depth = 0
	link_impl(argc, argv, i, 1)
	defhash_dump()
	return 0


/*
w symbols [--json] [--layout] [x64|arm64|arm64_darwin|arm64_ios|arm64_ios_sim|win64] <file.w>...

Compiles like 'w check' (output to /dev/null), then dumps the global symbol
table and user-declared types with their declaration locations. --json emits
one NDJSON record per entry on stdout, mirroring 'w check --json'. Entries
without a recorded location (runtime stubs declared before any source file)
are skipped.

--layout switches to the struct-layout view: only struct and union type
records print, each with its total size and one line (or JSON object) per
field carrying the field's byte offset and size as the compiler computed
them for the selected target. Offsets are the compiler's packed layout
(fields sum with no alignment padding; union fields all sit at 0) — the
native type table has no alignment metadata. Structs imported via c_import
DO carry real C ABI layout: the importer materializes alignment padding and
bit-field storage as explicit __ci_pad_ and __ci_bytes filler fields, so the
dump shows the true offsets. Imported types have no source location and are
skipped by the default view; --layout includes them with the "<c_import>"
file marker. Composes with the arch selectors in either spelling
('w symbols --layout x64 f.w' or 'w x64 symbols --layout f.w'), so per-arch
layouts are inspectable without running a binary.
*/


# Type name with pointer stars appended, e.g. "char*". Caller frees.
char* symbols_type_display(int type):
	if (type < 0): return strclone(c"<none>")
	char* name = strclone(type_get_name(type))
	int stars = type_get_pointer_level(type)
	while (stars > 0):
		char* with_star = strjoin(name, c"*")
		free(name)
		name = with_star
		stars = stars - 1
	return name


char* symbols_kind_name(int symtype):
	if (symtype == 2): return c"function"
	if (symtype == 1): return c"object"
	return c"notype"


# Kind of a type-table record from its RAW kind tag (type_get_kind would
# follow alias targets). Only struct/union/enum/alias/fn declarations record
# locations, so the default is "struct".
char* symbols_type_kind_name(int type_index):
	type_rec* t = type_record(type_index)
	int kind = t.kind
	if (kind == type_kind_alias): return c"alias"
	if (kind == type_kind_union): return c"union"
	if (kind == type_kind_enum): return c"enum"
	if (kind == type_kind_function): return c"fn"
	return c"struct"


# Struct/union field list as a JSON array:
# [{"name", "type", "offset", "size"}...]. type_index must be a struct or
# union; callers check the kind first.
void symbols_emit_fields_json(int type_index):
	diag_write_json_string(c"fields")
	diag_write_cstr(c": [")
	int n = type_num_args(type_index)
	for i in range(n):
		if (i > 0): diag_write_cstr(c", ")
		int field_type = type_get_field_type_at(type_index, i)
		char* field_display = symbols_type_display(field_type)
		diag_write_cstr(c"{")
		diag_write_json_field(c"name", type_get_field_name_at(type_index, i))
		diag_write_cstr(c", ")
		diag_write_json_field(c"type", field_display)
		diag_write_cstr(c", ")
		diag_write_json_int_field(c"offset", type_get_field_offset_at(type_index, i))
		diag_write_cstr(c", ")
		diag_write_json_int_field(c"size", type_get_size(field_type))
		diag_write_cstr(c"}")
		free(field_display)
	diag_write_cstr(c"]")


# Arch label for the emitted records. diag_word_size alone cannot tell the
# 8-byte-word targets apart (x64, arm64, arm64_darwin and win64 all set it
# to 8), so consult the ISA and OS the selector applied.
char* symbols_arch_name():
	if (target_isa == 1):
		if (target_os == 1):
			if (target_apple_platform == 2): return c"arm64_ios"
			if (target_apple_platform == 7): return c"arm64_ios_sim"
			return c"arm64_darwin"
		return c"arm64"
	if (target_isa == 2): return c"wasm"
	if (target_os == 2): return c"win64"
	if (diag_word_size == 8): return c"x64"
	return c"x86"


# type_index is the declared type's own index for a type-table entry (so
# struct/union kinds can carry a "fields" array), or -1 for symbol-table
# entries (functions, globals, enum constants), which have no fields.
# file_index -1 marks a type with no source location (c_import types in the
# --layout view); it prints with the "<c_import>" file marker.
void symbols_emit_json(char* name, char* kind, char* type_name, int file_index, int line, int column, int type_index):
	char* file_name = debug_file_name(file_index)
	if (file_index < 0): file_name = c"<c_import>"
	diag_write_cstr(c"{")
	diag_write_json_field(c"name", name)
	diag_write_cstr(c", ")
	diag_write_json_field(c"kind", kind)
	diag_write_cstr(c", ")
	diag_write_json_field(c"type", type_name)
	diag_write_cstr(c", ")
	diag_write_json_field(c"file", file_name)
	diag_write_cstr(c", ")
	diag_write_json_int_field(c"line", line)
	diag_write_cstr(c", ")
	diag_write_json_int_field(c"column", column)
	diag_write_cstr(c", ")
	diag_write_json_field(c"arch", symbols_arch_name())
	if (type_index >= 0):
		if ((strcmp(kind, c"struct") == 0) | (strcmp(kind, c"union") == 0)):
			diag_write_cstr(c", ")
			diag_write_json_int_field(c"total_size", type_get_size(type_index))
			diag_write_cstr(c", ")
			symbols_emit_fields_json(type_index)
	diag_write_cstr(c"}\x0a")
	diag_flush()


void symbols_emit_human(char* name, char* kind, char* type_name, int file_index, int line, int column):
	diag_write_cstr(debug_file_name(file_index))
	diag_write_cstr(c":")
	char* line_digits = itoa(line)
	diag_write_cstr(line_digits)
	free(line_digits)
	diag_write_cstr(c":")
	char* column_digits = itoa(column)
	diag_write_cstr(column_digits)
	free(column_digits)
	diag_write_cstr(c": ")
	diag_write_cstr(kind)
	diag_write_cstr(c" ")
	diag_write_cstr(name)
	diag_write_cstr(c": ")
	diag_write_cstr(type_name)
	diag_write_cstr(c"\x0a")
	diag_flush()


void symbols_emit(int json, char* name, char* kind, char* type_name, int file_index, int line, int column, int type_index):
	if (json): symbols_emit_json(name, kind, type_name, file_index, line, column, type_index)
	else: symbols_emit_human(name, kind, type_name, file_index, line, column)


void symbols_dump(int json):
	int t = 0
	while (t <= table_pos - 1):
		char* sym = table + t
		t = t + strlen(table + t)
		int file_index = sym_decl_file_index(t)
		if (file_index >= 0):
			char* type_name = symbols_type_display(load_int(table + t + 6))
			char* kind = symbols_kind_name(load_int(table + t + 10))
			symbols_emit(json, sym, kind, type_name, file_index, sym_decl_line(t), sym_decl_column(t), -1)
			free(type_name)
		t = next_token(t)
	# User-declared types: structs, unions, enums, and type aliases.
	int i = 0
	while (i < type_count()):
		if (type_decl_file_index(i) >= 0):
			symbols_emit(json, type_get_name(i), symbols_type_kind_name(i), type_get_name(i), type_decl_file_index(i), type_decl_line(i), type_decl_column(i), i)
		i = i + 1


# 1 when the type record belongs in the --layout view: a base (non-pointer)
# struct or union record that is either user-declared (has a source
# location) or field-carrying without one (c_import types). Built-in
# scalars are kind-0 records too but have neither fields nor a location.
int symbols_layout_wanted(int type_index):
	if (type_get_pointer_level(type_index) != 0): return 0
	type_rec* t = type_record(type_index)
	int kind = t.kind
	if ((kind != 0) && (kind != type_kind_union)): return 0
	if ((type_decl_file_index(type_index) < 0) && (type_num_args(type_index) == 0)): return 0
	return 1


void symbols_write_int(int value):
	char* digits = itoa(value)
	diag_write_cstr(digits)
	free(digits)


# Human layout block: the symbols header line with the total size
# appended, then one tab-indented line per field: offset, size, type,
# name (tab-separated). file_index -1 prints the "<c_import>" marker.
void symbols_emit_layout_human(int type_index, char* kind, int file_index, int line, int column):
	if (file_index >= 0): diag_write_cstr(debug_file_name(file_index))
	else: diag_write_cstr(c"<c_import>")
	diag_write_cstr(c":")
	symbols_write_int(line)
	diag_write_cstr(c":")
	symbols_write_int(column)
	diag_write_cstr(c": ")
	diag_write_cstr(kind)
	diag_write_cstr(c" ")
	diag_write_cstr(type_get_name(type_index))
	diag_write_cstr(c": size ")
	symbols_write_int(type_get_size(type_index))
	diag_write_cstr(c"\x0a")
	int n = type_num_args(type_index)
	for i in range(n):
		int field_type = type_get_field_type_at(type_index, i)
		char* field_display = symbols_type_display(field_type)
		diag_write_cstr(c"\x09")
		symbols_write_int(type_get_field_offset_at(type_index, i))
		diag_write_cstr(c"\x09")
		symbols_write_int(type_get_size(field_type))
		diag_write_cstr(c"\x09")
		diag_write_cstr(field_display)
		diag_write_cstr(c" ")
		diag_write_cstr(type_get_field_name_at(type_index, i))
		diag_write_cstr(c"\x0a")
		free(field_display)
	diag_flush()


# The --layout view: struct/union type records only (symbol-table entries
# and other type kinds are skipped), each with its total size and
# per-field offset/size. Includes c_import types, which the default view
# skips for lack of a source location.
void symbols_dump_layout(int json):
	int i = 0
	while (i < type_count()):
		if (symbols_layout_wanted(i)):
			char* kind = symbols_type_kind_name(i)
			int file_index = type_decl_file_index(i)
			int line = type_decl_line(i)
			int column = type_decl_column(i)
			if (json):
				symbols_emit_json(type_get_name(i), kind, type_get_name(i), file_index, line, column, i)
			else: symbols_emit_layout_human(i, kind, file_index, line, column)
		i = i + 1


int symbols_main(int argc, int argv):
	int i = 2
	int json = 0
	int layout = 0
	diag_json = 0
	# Leading flags in any order, like 'w check'.
	int scanning = 1
	while (scanning & (i < argc)):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--json") == 0):
			json = 1
			diag_json = 1
			i = i + 1
		else if (strcmp(*arg, c"--layout") == 0):
			layout = 1
			i = i + 1
		else if (import_root_arg_width(*arg) > 0):
			i = i + import_root_arg_width(*arg)
		else if (arg_is_help(*arg)):
			help_symbols()
			exit(0)
		else: scanning = 0
	if (argc <= i):
		println2(c"usage: w symbols [--json] [--layout] [x64|arm64|arm64_darwin|arm64_ios|arm64_ios_sim|win64|wasm] <file.w>... [--bounds=on|off|trap] [--pac=off|ret|full] [--strict]")
		println2(c"run 'w symbols --help' for details")
		exit(1)
	link_impl(argc, argv, i, 1)
	if (layout): symbols_dump_layout(json)
	else: symbols_dump(json)
	return 0


import compiler.retained_query
