import lib.lib
import compiler.tokenizer
import codegen
import lib.assert
import compiler.type_table
import compiler.symbol_table
import grammar
import compiler.test_registry


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
	int old_line_number = line_number + 1
	int old_column_number = column_number
	int old_diag_token_line = diag_token_line
	int old_diag_token_column = diag_token_column
	int old_tab_level = tab_level
	int old_byte_offset = byte_offset

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

	compile_file(fn)
	close(file)

	filename = old_filename
	file = old_file
	line_number = old_line_number
	column_number = old_column_number
	diag_token_line = old_diag_token_line
	diag_token_column = old_diag_token_column
	tab_level = old_tab_level
	byte_offset = old_byte_offset
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
