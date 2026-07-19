import lib.lib
import compiler.tokenizer
import codegen
import lib.assert
import compiler.type_table
import compiler.symbol_table
import grammar
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


# 'w deps' recording: while deps_mode is set, every file the compiler
# successfully opens for compilation (the root, every import, and the
# auto-imported runtime modules) is recorded here so deps_dump() can
# print the transitive import closure after the compile finishes.
int deps_mode
char* deps_paths
int deps_count

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
		deps_paths = malloc(max_deps * __word_size__)
	assert1(deps_count < max_deps)
	save_ptr(deps_paths + deps_count * __word_size__, cast(int, strclone(path)))
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
	if (token == 0):
		token = path


int compile_attempt(char* fn):
	# The caller owns fn and frees it after a failed attempt, so a
	# failure must not leave the global filename pointing at it: the
	# search-exhausted diagnostic would print the freed bytes (#190)
	char* old_filename = filename
	filename = fn
	file = open(filename, 0, 511)
	if (file < 0):
		if (verbosity >= 1):
			file_not_found_error()
		filename = old_filename
		return 0
	if (deps_mode):
		deps_record(filename)
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
			if (getc() == 191):
				nextc = getc()
	get_token()
	program()
	return 1


# Normalize path separators in-place: replace every '\' (92) with '/' (47).
# Windows GetCurrentDirectoryA returns backslash-separated paths; the rest
# of the path logic uses '/' uniformly so cross-platform paths just work.
# Only active on Windows: on Unix a backslash is an ordinary filename
# character and must be left alone.
void path_normalize_sep(char* p):
	if (os_windows() == 0):
		return
	while (p[0] != 0):
		if (p[0] == 92):
			p[0] = 47
		p = p + 1


# Return 1 if the path is absolute: starts with '/' (Unix) or with a
# Windows drive letter and colon (e.g. 'C:\', 'C:/', 'c:').
int path_is_absolute(char* p):
	if (p[0] == 47):
		return 1
	# Windows drive letter: an ASCII letter at [0], colon at [1]. The
	# letter check keeps ':' in ordinary Unix filenames from matching
	# (and never reads p[1] when the string is empty).
	int first = p[0] | 32
	if ((first >= 'a') && (first <= 'z') && (p[1] == 58)):
		return 1
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
	if (result == 0):
		free(joined2)
	return result


# fn must not shadow the global filename: the search-exhausted branch
# below reads and repoints the global.
int compile_relative_path(char* fn):
	# Get current directory
	int max_path_size = 4096
	char* cwd = malloc(max_path_size)
	getcwd(cwd, max_path_size)
	# Normalize backslashes from Windows GetCurrentDirectoryA to forward slashes
	path_normalize_sep(cwd)

	# While we still have path remaining:
	while (cwd[0]):

		# Attempt to compile with this path
		int result = compile_joined(cwd, fn)

		# If successfull return
		if (result == 1):
			free(cwd)
			return 1

		# Go back up one directory
		int index = strlen(cwd) - 1
		while (index >= 0):
			if (cwd[index] == 47):
				cwd[index] = 0
				index = 0 /* hacky way to break from loop */
			index = index - 1
		if (verbosity >= 1):
			print_string(c"went up one directory: ", cwd)

	free(cwd)
	# Point the diagnostic at the import statement when an importing
	# file is current; at cold start (the auto-imported container
	# runtime) fall back to the searched path itself.
	if (filename == 0):
		missing_file_reset(fn)
	diag_part(c"cannot locate '")
	diag_part(fn)
	# error() instead of exit() so a REPL entry importing a missing
	# module recovers to the prompt instead of killing the session
	error(c"' (searched the current directory and every parent)")
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
		if (compile_attempt(path)):
			return 1
	else:
		int max_path_size = 4096
		char* cwd = malloc(max_path_size)
		getcwd(cwd, max_path_size)
		path_normalize_sep(cwd)
		int result = compile_joined(cwd, path)
		free(cwd)
		if (result):
			return 1
	missing_file_reset(path)
	diag_part(c"no such file: '")
	diag_part(path)
	error(c"'")
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

	if (verbosity >= 0):
		print_string(c"compiling ", fn)

	# defhash's root-vs-import scoping (defhash_note, above) reads this:
	# 0 while the tokens just parsed belong directly to a command-line
	# root argument, >0 while inside an import's own nested compile.
	# Bracketing compile_file() here covers every import, direct or
	# transitive (including the auto-imported container-runtime closure,
	# which reaches this same path through import_module).
	defhash_depth = defhash_depth + 1
	compile_file(fn)
	close(file)
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

	if (verbosity >= 0):
		print_string(c"back to ", filename)


# The recognized target-selector words, shared by link_impl's positional
# parse and the selector-first subcommand spelling ('w x64 check f.w')
# that main() forwards through target_pending.
int target_is_selector(char* arg):
	if (strcmp(arg, c"x64") == 0):
		return 1
	if (strcmp(arg, c"arm64") == 0):
		return 1
	if (strcmp(arg, c"arm64_darwin") == 0):
		return 1
	if (strcmp(arg, c"win64") == 0):
		return 1
	if (strcmp(arg, c"wasm") == 0):
		return 1
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
		if (quiet_mode == 0):
			println2(c"Compiling in x64 mode")
		word_size =  8
		word_size_log2 = 3
		diag_word_size = word_size
		return 1
	if (strcmp(arg, c"arm64") == 0):
		if (quiet_mode == 0):
			println2(c"Compiling in arm64 mode")
		# AArch64 is a 64-bit target, so it inherits the x64 type system
		# (8-byte pointers, int64, float64); target_isa selects the A64
		# instruction emitter and the Mach-O/ELF-arm64 container.
		word_size = 8
		word_size_log2 = 3
		diag_word_size = word_size
		target_isa = 1
		# W^X: arm64 executables get a read-execute code segment and a
		# separate read-write data segment (Stage 3). x86/x64 keep the
		# single RWX image so their output stays byte-identical and the
		# dynamic-linker GOT stays writable.
		data_split = 1
		return 1
	if (strcmp(arg, c"wasm") == 0):
		if (quiet_mode == 0):
			println2(c"Compiling in wasm mode")
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
		if (quiet_mode == 0):
			println2(c"Compiling in win64 mode")
		# Windows x64: the x86-64 instruction emitter (target_isa 0,
		# word_size 8) with the PE32+ container and a kernel32-import
		# runtime instead of Linux syscalls (docs/projects/windows.md).
		word_size = 8
		word_size_log2 = 3
		diag_word_size = word_size
		target_os = 2
		return 1
	if (strcmp(arg, c"arm64_darwin") == 0):
		if (quiet_mode == 0):
			println2(c"Compiling in arm64_darwin mode")
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
	if (starts_with(trimmed, c"./")):
		trimmed = trimmed + 2
	char* canonical = strclone(trimmed)
	free(normalized)
	if (ends_with(canonical, c".w")):
		canonical[strlen(canonical) - 2] = 0
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
	if (starts_with(canonical, c"compiler/")):
		internal = 1
	if (starts_with(canonical, c"grammar/")):
		internal = 1
	if (starts_with(canonical, c"code_generator/")):
		internal = 1
	if (starts_with(canonical, c"debugger/")):
		internal = 1
	if (strcmp(canonical, c"codegen") == 0):
		internal = 1
	if (strcmp(canonical, c"grammar") == 0):
		internal = 1
	free(canonical)
	return internal


int link_impl(int argc, int argv, int start_index, int check_mode):
	if (argc <= start_index):
		println2(c"usage: w [x64|arm64|arm64_darwin|win64|wasm] <file.w>... [-o output] [--bounds=on|off|trap] [--pac=off|ret|full] [--strict] [--quiet] [--version]")
		exit(1)
	int i = start_index
	word_size = 4
	word_size_log2 = 2
	diag_word_size = word_size
	target_isa = 0
	target_os = 0
	arm64_pac = 1
	bounds_mode = 1
	strict_mode = 0
	warning_count = 0
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
	# argv strides by the HOST pointer size: __word_size__ was baked in
	# when this compiler binary was itself compiled
	char** first_arg = argv + i * __word_size__
	if (target_selector_apply(*first_arg)):
		i = i + 1
	# --pac is whole-program: signing at materialization and authenticating
	# at the call site must agree across every compiled file (a mixed image
	# would trap at runtime), and the Mach-O header consumes the level in
	# be_start below. So the level is fixed by a pre-scan of the remaining
	# arguments here; the positional flag loop merely re-applies it.
	int pac_level = arm64_pac
	int pac_scan = i
	while (pac_scan < argc):
		char** pac_arg = argv + pac_scan * __word_size__
		if (strcmp(*pac_arg, c"--pac=off") == 0):
			pac_level = 0
		else if (strcmp(*pac_arg, c"--pac=ret") == 0):
			pac_level = 1
		else if (strcmp(*pac_arg, c"--pac=full") == 0):
			pac_level = 2
		pac_scan = pac_scan + 1
	arm64_pac = pac_level
	push_basic_types()
	pointer_indirection = 0
	# No function body is being compiled yet: the '?' operator checks
	# this to reject uses outside a function.
	current_function_symbol = -1
	last_identifier = malloc(8000)
	last_global_declaration = malloc(8000)
	be_start(word_size)
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
	check_imports_mode = import_check_saved
	check_bool_ops_mode = bool_ops_check_saved
	# Everything registered so far (hash_table, w_list, and whatever they
	# transitively import: lib/memory.w, lib/stack_trace.w, ...) is the
	# auto-imported container-runtime closure that --imports treats like
	# a direct import for every file (grammar/import_statement.w).
	auto_import_closure_count = imported_count

	output_fd = 1 /* default: write the ELF to stdout */
	char* output_path = 0

	while (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"-o") == 0):
			i = i + 1
			asserts(c"-o requires an output path", i < argc)
			arg = argv + i * __word_size__
			output_path = *arg
		else if (strcmp(*arg, c"--bounds=on") == 0):
			bounds_mode = 1
		else if (strcmp(*arg, c"--bounds=trap") == 0):
			bounds_mode = 1
		else if (strcmp(*arg, c"--bounds=off") == 0):
			bounds_mode = 0
		else if (strcmp(*arg, c"--pac=off") == 0):
			arm64_pac = pac_level
		else if (strcmp(*arg, c"--pac=ret") == 0):
			arm64_pac = pac_level
		else if (strcmp(*arg, c"--pac=full") == 0):
			arm64_pac = pac_level
		else if (strcmp(*arg, c"--strict") == 0):
			strict_mode = 1
		else if (strcmp(*arg, c"--quiet") == 0):
			quiet_mode = 1
		else if (starts_with(*arg, c"--ptx=")):
			# Debug dump of the embedded PTX module (kernels/'gpu for'),
			# written by ptx_finish_module; ignored when no kernels exist.
			ptx_dump_path = *arg + 6
		else if (starts_with(*arg, c"-")):
			# Every recognized flag was matched above; a dash-prefixed
			# argument that reaches here is a typo or an unsupported
			# option ('--bounds=xyz', '--nope'), not an input file — a
			# file named '-x' is vanishingly rare in this codebase, and
			# treating it as a root instead produced a misleading "no
			# such file: '--bounds=xyz'" (the fallthrough below tried to
			# open it). Fail fast with the option text instead of
			# silently compiling it as a root.
			print_error(c"unrecognized option: '")
			print_error(*arg)
			print_error(c"'\x0a")
			exit(1)
		else:
			char* input = *arg
			# A compiler-internal root cannot be checked standalone;
			# check w.w in its place (rule: root_is_compiler_internal)
			if (check_mode && root_is_compiler_internal(input)):
				if (quiet_mode == 0):
					print_error(c"check: ")
					print_error(input)
					print_error(c" is compiler-internal; checking w.w\x0a")
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
				if (quiet_mode == 0):
					print_error(c"compiling '")
					print_error(input)
					print_error(c"'\x0a")
				compile_input_file(input)
		i = i + 1

	# Queued generic instantiations compile at this top-level boundary,
	# before the runtime imports so instantiated bodies can rely on the
	# to_json/template-string finishers below; a second drain afterwards
	# covers instantiations those runtime modules might request.
	generic_finish_instantiations()

	# On-demand runtimes for the to_json/from_json builtins and f"..."
	# template strings: imported after all user files so the modules'
	# code lands at a top-level boundary. Like the auto-import closure
	# above, these are compiler-injected modules, so --bool-ops's extra
	# call-containing reporting stays quiet while they compile — their
	# remaining '&'/'|' sites are deliberate (structures/prelude.w and
	# friends), and would otherwise warn on every --bool-ops check of any
	# file regardless of what that file itself contains.
	int bool_ops_finish_saved = check_bool_ops_mode
	check_bool_ops_mode = 0
	json_codec_finish_import()
	template_string_finish_import()
	prelude_finish_import()
	generic_finish_instantiations()
	var_finish_import()
	check_bool_ops_mode = bool_ops_finish_saved

	# Synthesize __w_test_main for lib/testing.w consumers now that every
	# test_* function is compiled (compiler/test_registry.w, issue #147)
	test_registry_finish()

	# Embed the PTX module behind __w_ptx_module (and honor --ptx=<path>)
	# for programs that declared gpu kernels (code_generator/ptx.w)
	ptx_finish_module()

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
		asserts(c"could not open output file", output_fd >= 0)
	if (check_mode):
		output_fd = open(c"/dev/null", 577, 493)
		if (output_fd < 0):
			# Windows: /dev/null does not exist; use the NUL device instead
			output_fd = open(c"NUL", 577, 493)
		asserts(c"could not open null device", output_fd >= 0)

	# print_symbol_table(0)
	# type_print_all()
	# The debugging symbols are ELF section headers plus DWARF, and
	# elf_save_section_info patches the section-header offset into the ELF
	# header at fixed positions — bytes that belong to load commands in a
	# Mach-O and to the COFF header in a PE. Only the ELF (Linux) targets
	# get them; Mach-O and PE debug info are later stages.
	if (target_os == 0):
		emit_debugging_symbols(word_size)
	be_finish(word_size)

	if ((output_path != 0) | check_mode):
		close(output_fd)

	return 0


int link(int argc, int argv):
	return link_impl(argc, argv, 1, 0)


int check_main(int argc, int argv):
	int i = 2
	diag_json = 0
	check_imports_mode = 0
	check_bool_ops_mode = 0
	# Leading flags in any order; --quiet must be consumed before
	# link_impl sees the argument list so the x64/arm64 mode banner and
	# the per-file banner are suppressed from the start.
	int scanning = 1
	while (scanning & (i < argc)):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--json") == 0):
			diag_json = 1
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
		else:
			scanning = 0
	if (argc <= i):
		println2(c"usage: w check [--json] [--quiet] [--imports] [--bool-ops] [x64|arm64|arm64_darwin|win64] <file.w>... [--bounds=on|off|trap] [--pac=off|ret|full] [--strict]")
		exit(1)
	return link_impl(argc, argv, i, 1)


/*
w deps [--json] [x64|arm64|arm64_darwin|win64] <file.w>...

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


void deps_emit(int json, char* path):
	if (json):
		diag_write_cstr(c"{")
		diag_write_json_field(c"file", path)
		diag_write_cstr(c"}\x0a")
	else:
		diag_write_cstr(path)
		diag_write_cstr(c"\x0a")
	diag_flush()


void deps_dump(int json):
	int max_path_size = 4096
	char* cwd = malloc(max_path_size)
	getcwd(cwd, max_path_size)
	int cwd_len = strlen(cwd)
	int i = 0
	while (i < deps_count):
		char* path = cast(char*, load_ptr(deps_paths + i * __word_size__))
		# Deduplicate on the recorded (absolute) path
		int duplicate = 0
		int j = 0
		while (j < i):
			char* seen = cast(char*, load_ptr(deps_paths + j * __word_size__))
			if (strcmp(seen, path) == 0):
				duplicate = 1
			j = j + 1
		if (duplicate == 0):
			char* shown = path
			if (starts_with(path, cwd)):
				if (path[cwd_len] == '/'):
					shown = path + cwd_len + 1
			deps_emit(json, shown)
		i = i + 1
	free(cwd)


int deps_main(int argc, int argv):
	int i = 2
	int json = 0
	diag_json = 0
	if (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--json") == 0):
			json = 1
			diag_json = 1
			i = i + 1
	if (argc <= i):
		println2(c"usage: w deps [--json] [x64|arm64|arm64_darwin|win64] <file.w>... [--bounds=on|off|trap] [--pac=off|ret|full] [--strict]")
		exit(1)
	deps_mode = 1
	link_impl(argc, argv, i, 1)
	deps_dump(json)
	return 0


/*
w defhash [--closure] [x64|arm64|arm64_darwin|win64] <file.w>...

Compiles like 'w check' (output to /dev/null), then prints one NDJSON
record per top-level definition (function, global variable, struct,
union, enum, type alias) declared directly in the root file(s) named on
the command line: {"file", "name", "kind", "hash", "refs"}. "hash" is a
sha256 over the definition's own token stream -- kind+text pairs,
whitespace and comments excluded -- so a reformatting or comment-only
edit leaves it unchanged while any real content edit changes it. "refs"
lists the OTHER recorded definitions' names that appear as an identifier
token inside the definition's span (deduplicated, sorted), the
approximation of "symbols this definition depends on" described in
docs/projects/build_system_next.md's 4a.

Scope: by default only definitions declared directly in the command-line
root file(s) are recorded -- not their imports, and not the
auto-imported container-runtime closure every program pulls in. --closure
widens that to every definition in the whole compiled program, matching
'deps' full transitive-closure scope. Root-vs-import scoping is tracked
by defhash_depth (see compile_save below) rather than by comparing
paths: 0 while the tokens just parsed belong directly to a root
argument, >0 while inside an import's own nested compile.

Exclusions (documented, not bugs): generic struct/function definitions
and 'operator' overload definitions are never recorded -- the scan-ahead
and re-parse machinery those go through (grammar/generic.w,
grammar/operator_overload.w) never reaches defhash_note's call sites, so
their bodies are invisible to defhash today. A struct/union field name or
enum constant that happens to share text with another top-level
definition's name is indistinguishable, in this token-stream scan, from a
real reference to it, and so can appear as a false-positive ref; the
scan also does not special-case shadowing (a parameter or local that
reuses another definition's name reads as a reference to it). "Source
order" is the order definitions were recorded in, which is exactly
file-order for the default (single root, no --closure) case; --closure
interleaves recording across files in compile-visitation order rather
than a stable (file, offset) sort.
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


# Called by the grammar's top-level declaration recognizers (struct,
# union, enum and type-alias declarations in their own grammar/*.w
# files; the plain function/global branch in grammar/program.w) once a
# definition's full span is known. A no-op whenever defhash_mode is off,
# so this is safe to call unconditionally -- and every one of those call
# sites does, since 'kind' is only known at the very end of a successful
# parse anyway.
void defhash_note(char* name, char* kind, int file_index, int line, int column, int start_offset, int end_offset):
	if (defhash_mode == 0):
		return
	if ((defhash_closure_mode == 0) && (defhash_depth != 0)):
		return
	int max_defs = 8000
	if (defhash_names == 0):
		defhash_names = malloc(max_defs * __word_size__)
		defhash_kinds = malloc(max_defs * __word_size__)
		defhash_file_indexes = malloc(max_defs * __word_size__)
		defhash_lines = malloc(max_defs * __word_size__)
		defhash_columns = malloc(max_defs * __word_size__)
		defhash_starts = malloc(max_defs * __word_size__)
		defhash_ends = malloc(max_defs * __word_size__)
	assert1(defhash_count < max_defs)
	save_ptr(defhash_names + defhash_count * __word_size__, cast(int, name))
	save_ptr(defhash_kinds + defhash_count * __word_size__, cast(int, kind))
	save_ptr(defhash_file_indexes + defhash_count * __word_size__, file_index)
	save_ptr(defhash_lines + defhash_count * __word_size__, line)
	save_ptr(defhash_columns + defhash_count * __word_size__, column)
	save_ptr(defhash_starts + defhash_count * __word_size__, start_offset)
	save_ptr(defhash_ends + defhash_count * __word_size__, end_offset)
	defhash_count = defhash_count + 1


# Classification tag for one token's text, used only to keep the hashed
# byte stream unambiguous (defhash_process_span appends "<kind><len>:
# <text>" per token) -- not a full lexical classification. Keywords and
# identifiers deliberately share 'i': the token TEXT already
# distinguishes 'if' from a variable named 'if_ready', and nothing
# downstream needs the finer distinction.
char* defhash_token_kind(char* tok):
	int c0 = tok[0] & 255
	if (c0 == 0):
		return c"e"
	if (('0' <= c0) && (c0 <= '9')):
		return c"n"
	if (c0 == '"'):
		return c"s"
	if (c0 == 39):
		return c"h"
	if (((c0 == 's') || (c0 == 'c') || (c0 == 'f')) && (tok[1] == '"')):
		return c"s"
	if ((('a' <= c0) && (c0 <= 'z')) || (('A' <= c0) && (c0 <= 'Z')) || (c0 == '_')):
		return c"i"
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
		defhash_buf = malloc(defhash_buf_size)
	while (defhash_buf_size <= defhash_buf_pos + n):
		int old_size = defhash_buf_size
		defhash_buf_size = defhash_buf_size << 1
		defhash_buf = realloc(defhash_buf, old_size, defhash_buf_size)


void defhash_buf_append_n(char* s, int len):
	defhash_buf_ensure(len)
	int i = 0
	while (i < len):
		defhash_buf[defhash_buf_pos] = s[i]
		defhash_buf_pos = defhash_buf_pos + 1
		i = i + 1


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
		defhash_refs_buf = malloc(defhash_refs_cap * __word_size__)
	defhash_refs_count = 0


int defhash_refs_contains(char* name):
	int i = 0
	while (i < defhash_refs_count):
		if (strcmp(cast(char*, load_ptr(defhash_refs_buf + i * __word_size__)), name) == 0):
			return 1
		i = i + 1
	return 0


void defhash_refs_add(char* name):
	if (defhash_refs_contains(name)):
		return
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


# 1 when 'name' matches some OTHER recorded definition's name (a linear
# scan over defhash_count; defhash runs are small enough -- a single
# file by default, the whole program only under --closure -- that this
# stays well under the cost of the tokenizing it runs alongside).
int defhash_is_known_definition(char* name):
	int i = 0
	while (i < defhash_count):
		if (strcmp(cast(char*, load_ptr(defhash_names + i * __word_size__)), name) == 0):
			return 1
		i = i + 1
	return 0


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
	while ((token[0] != 0) && (token_start_offset < end_offset)):
		char* kind = defhash_token_kind(token)
		defhash_buf_append(kind)
		char* len_digits = itoa(strlen(token))
		defhash_buf_append(len_digits)
		free(len_digits)
		defhash_buf_append(c":")
		defhash_buf_append(token)
		if ((strcmp(kind, c"i") == 0) && (prev_was_dot == 0) && (strcmp(token, self_name) != 0)):
			if (defhash_is_known_definition(token)):
				defhash_refs_add(token)
		prev_was_dot = strcmp(token, c".") == 0
		get_token()
	defhash_rehash_mode = 0
	close(f)
	defhash_refs_sort()


char* defhash_hex_digits(char* digest):
	char* hex = malloc(65)
	int i = 0
	while (i < 32):
		hex[i * 2] = diag_hex_digit((digest[i] >> 4) & 15)
		hex[i * 2 + 1] = diag_hex_digit(digest[i] & 15)
		i = i + 1
	hex[64] = 0
	return hex


void defhash_emit(int idx, char* cwd, int cwd_len):
	char* name = cast(char*, load_ptr(defhash_names + idx * __word_size__))
	char* kind = cast(char*, load_ptr(defhash_kinds + idx * __word_size__))
	int file_index = load_ptr(defhash_file_indexes + idx * __word_size__)
	char* path = debug_file_name(file_index)
	char* shown = path
	if (starts_with(path, cwd)):
		if (path[cwd_len] == '/'):
			shown = path + cwd_len + 1

	defhash_process_span(idx)
	char* digest = malloc(32)
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
		if (j > 0):
			diag_write_cstr(c", ")
		diag_write_json_string(cast(char*, load_ptr(defhash_refs_buf + j * __word_size__)))
		j = j + 1
	diag_write_cstr(c"]}\x0a")
	diag_flush()
	free(hex)


void defhash_dump():
	int max_path_size = 4096
	char* cwd = malloc(max_path_size)
	getcwd(cwd, max_path_size)
	int cwd_len = strlen(cwd)
	int i = 0
	while (i < defhash_count):
		defhash_emit(i, cwd, cwd_len)
		i = i + 1
	free(cwd)


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
		else:
			scanning = 0
	if (argc <= i):
		println2(c"usage: w defhash [--closure] [x64|arm64|arm64_darwin|win64] <file.w>... [--bounds=on|off|trap] [--pac=off|ret|full] [--strict]")
		exit(1)
	defhash_mode = 1
	defhash_depth = 0
	link_impl(argc, argv, i, 1)
	defhash_dump()
	return 0


/*
w symbols [--json] [x64|arm64|arm64_darwin|win64] <file.w>...

Compiles like 'w check' (output to /dev/null), then dumps the global symbol
table and user-declared types with their declaration locations. --json emits
one NDJSON record per entry on stdout, mirroring 'w check --json'. Entries
without a recorded location (runtime stubs declared before any source file)
are skipped.
*/


# Type name with pointer stars appended, e.g. "char*". Caller frees.
char* symbols_type_display(int type):
	if (type < 0):
		return strclone(c"<none>")
	char* name = strclone(type_get_name(type))
	int stars = type_get_pointer_level(type)
	while (stars > 0):
		char* with_star = strjoin(name, c"*")
		free(name)
		name = with_star
		stars = stars - 1
	return name


char* symbols_kind_name(int symtype):
	if (symtype == 2):
		return c"function"
	if (symtype == 1):
		return c"object"
	return c"notype"


# Kind of a type-table record from its RAW kind tag (type_get_kind would
# follow alias targets). Only struct/union/enum/alias/fn declarations record
# locations, so the default is "struct".
char* symbols_type_kind_name(int type_index):
	int t = cast(int, type_record(type_index))
	int kind = load_ptr(t + 205 * __word_size__)
	if (kind == type_kind_alias):
		return c"alias"
	if (kind == type_kind_union):
		return c"union"
	if (kind == type_kind_enum):
		return c"enum"
	if (kind == type_kind_function):
		return c"fn"
	return c"struct"


# Struct/union field list as a JSON array: [{"name", "type", "offset"}...].
# type_index must be a struct or union; callers check the kind first.
void symbols_emit_fields_json(int type_index):
	diag_write_json_string(c"fields")
	diag_write_cstr(c": [")
	int n = type_num_args(type_index)
	int i = 0
	while (i < n):
		if (i > 0):
			diag_write_cstr(c", ")
		char* field_type = symbols_type_display(type_get_field_type_at(type_index, i))
		diag_write_cstr(c"{")
		diag_write_json_field(c"name", type_get_field_name_at(type_index, i))
		diag_write_cstr(c", ")
		diag_write_json_field(c"type", field_type)
		diag_write_cstr(c", ")
		diag_write_json_int_field(c"offset", type_get_field_offset_at(type_index, i))
		diag_write_cstr(c"}")
		free(field_type)
		i = i + 1
	diag_write_cstr(c"]")


# type_index is the declared type's own index for a type-table entry (so
# struct/union kinds can carry a "fields" array), or -1 for symbol-table
# entries (functions, globals, enum constants), which have no fields.
void symbols_emit_json(char* name, char* kind, char* type_name, int file_index, int line, int column, int type_index):
	char* arch = c"x86"
	if (diag_word_size == 8):
		arch = c"x64"
	diag_write_cstr(c"{")
	diag_write_json_field(c"name", name)
	diag_write_cstr(c", ")
	diag_write_json_field(c"kind", kind)
	diag_write_cstr(c", ")
	diag_write_json_field(c"type", type_name)
	diag_write_cstr(c", ")
	diag_write_json_field(c"file", debug_file_name(file_index))
	diag_write_cstr(c", ")
	diag_write_json_int_field(c"line", line)
	diag_write_cstr(c", ")
	diag_write_json_int_field(c"column", column)
	diag_write_cstr(c", ")
	diag_write_json_field(c"arch", arch)
	if (type_index >= 0):
		if ((strcmp(kind, c"struct") == 0) | (strcmp(kind, c"union") == 0)):
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
	if (json):
		symbols_emit_json(name, kind, type_name, file_index, line, column, type_index)
	else:
		symbols_emit_human(name, kind, type_name, file_index, line, column)


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


int symbols_main(int argc, int argv):
	int i = 2
	int json = 0
	diag_json = 0
	if (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"--json") == 0):
			json = 1
			diag_json = 1
			i = i + 1
	if (argc <= i):
		println2(c"usage: w symbols [--json] [x64|arm64|arm64_darwin|win64] <file.w>... [--bounds=on|off|trap] [--pac=off|ret|full] [--strict]")
		exit(1)
	link_impl(argc, argv, i, 1)
	symbols_dump(json)
	return 0
