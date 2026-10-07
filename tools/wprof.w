# wbuild: binary=wprof arch=x64
# wbuild: target=profile_refresh dep=build dep=build_x64 dep=wprof
# wbuild: step="bin/wv2 --profile-generate --strict w.w -o bin/prof_wv3"
# wbuild: step="bin/wprof clear bin/self.wprofraw"
# wbuild: step="bin/prof_wv3 --quiet w.w -o bin/prof_self_out" env="W_PROFILE_OUT=bin/self.wprofraw"
# wbuild: step="bin/wprof merge -o profiles/self.wprof bin/prof_wv3.wprofmap bin/self.wprofraw"
# wbuild: step="bin/wv2_64 x64 --profile-generate --strict w.w -o bin/prof_wv3_64"
# wbuild: step="bin/wprof clear bin/self_x64.wprofraw"
# wbuild: step="bin/prof_wv3_64 x64 --quiet w.w -o bin/prof_self_out_64" env="W_PROFILE_OUT=bin/self_x64.wprofraw"
# wbuild: step="bin/wprof merge -o profiles/self_x64.wprof bin/prof_wv3_64.wprofmap bin/self_x64.wprofraw"
# wbuild: step="bin/wprof corpus -o profiles/bench.wprof --compiler bin/wv2 tests/bench"
/*
wprof: merge and inspect --profile-generate output (unit P1,
docs/projects/register_allocation_pgo.md §3.3).

  bin/wprof merge [-o <out.wprof>] [--zeros] <map-or-dump-or-wprof>...
      Every <x>.wprofmap argument opens a group; the raw dump files that
      follow it (the $W_PROFILE_OUT appends of binaries compiled with
      that map) are resolved against it. A <x>.wprof argument is an
      existing profile whose entries are merged as they are. Counts for
      the same (defhash, kind, loop ordinal) key are summed across every
      input, and the result is written sorted (stdout without -o):

        # wprof v1 from: <inputs>
        f <defhash> <name> <file> <line> entries=<n>
        l <defhash> <name> <file> <line> head=<ordinal> iters=<n>

      Only keys whose count is nonzero are written unless --zeros is
      given: a definition absent from a profile is "unknown" to the
      compiler (the static heuristic applies), which is also the right
      reading for one that was compiled in but never ran. Loop counts
      are head evaluations (iterations + 1 per entry that leaves through
      the condition), see code_generator/profile_counters.w.

  bin/wprof stats [--compiler <w>] <profile.wprof> <file.w>...
      How much of a profile still matches a source tree: runs
      '<w> defhash --closure <file.w>' (default compiler bin/wv2) for
      the files, collects the current function/operator/generic_function
      hashes, and prints the share of the profile's functions and
      entries that match them — the staleness number a PR body quotes.

  bin/wprof top [-n <count>] [-f|-l] <profile.wprof>
      The hottest functions (by entries) and loops (by iters).

  bin/wprof clear <path>...
      Truncate (or create) the named raw dump files: the step before a
      profiled run, since the runtime only ever appends.

  bin/wprof corpus [-o <out.wprof>] [--compiler <w>] [--arch <sel>] <dir>
      Compile every <dir>/*.w with --profile-generate, run each once
      with no arguments, and merge the dumps into one profile. A missing
      or empty directory yields a header-only profile and exit 0, so
      profile_refresh (the directive block above) works before the
      benchmark corpus (unit B1, tests/bench/) lands. Programs that fail
      to compile or run are reported and skipped.

Built as a 64-bit tool (arch=x64 above) so merged counts are 64-bit;
the dumps themselves are written by lib/profile.w on either target.
*/
import lib.lib
import lib.str
import lib.file
import lib.env
import lib.process
import lib.dir
import structures.string


struct prof_entry:
	char* hash
	char* kind      # "f" or "l"
	int ordinal     # loop ordinal within the function, 0 for "f"
	char* name
	char* file
	int line
	int count


list[prof_entry*] prof_entries
map[char*, int] prof_index   # key -> index into prof_entries
list[char*] prof_inputs      # for the header line


void out(char* s):
	write(1, s, strlen(s))


void err(char* s):
	write(2, s, strlen(s))


void fail(char* what, char* detail):
	err(c"wprof: error: ")
	err(what)
	if (detail != 0):
		err(c": ")
		err(detail)
	err(c"\n")
	exit(1)


# Zero-padded ordinal so the key (and the output) sorts numerically.
char* prof_key(char* hash, char* kind, int ordinal):
	string_builder* key = string_new()
	string_append(key, hash)
	string_append(key, c"\t")
	string_append(key, kind)
	string_append(key, c"\t")
	char* digits = itoa(ordinal)
	int pad = 8 - strlen(digits)
	while (pad > 0):
		string_append(key, c"0")
		pad = pad - 1
	string_append(key, digits)
	free(digits)
	char* result = strclone(key.data)
	string_free(key)
	return result


# The entry for a key, created with the informational fields on first
# sight (a later input's name/file/line for the same key is ignored).
prof_entry* prof_entry_for(char* hash, char* kind, int ordinal, char* name, char* file, int line):
	if (prof_entries == 0):
		prof_entries = new list[prof_entry*]
		prof_index = new map[char*, int]
	char* key = prof_key(hash, kind, ordinal)
	if (key in prof_index):
		int at = prof_index[key]
		free(key)
		return prof_entries[at]
	prof_entry* e = new prof_entry()
	e.hash = strclone(hash)
	e.kind = strclone(kind)
	e.ordinal = ordinal
	e.name = strclone(name)
	e.file = strclone(file)
	e.line = line
	e.count = 0
	prof_index[key] = prof_entries.length
	prof_entries.push(e)
	return e


# --- the map sidecar ---------------------------------------------------

struct prof_map:
	char* path
	list[prof_entry*] by_index   # counter index -> entry (0 = unmapped)


prof_map* prof_map_load(char* path):
	list[char*] lines = file_read_lines(path)
	if (lines == 0): fail(c"cannot read map", path)
	if (lines.length == 0): fail(c"empty map", path)
	if (starts_with(lines[0], c"# wprofmap v1") == 0): fail(c"not a wprofmap v1 file", path)
	prof_map* m = new prof_map()
	m.path = path
	m.by_index = new list[prof_entry*]
	for int i in range(1, lines.length):
		char* line = lines[i]
		if (line[0] == 0): continue
		list[char*] fields = split(line, '\t')
		if (fields.length < 7): fail(c"malformed map line", line)
		int index = atoi(fields[0])
		if (index != m.by_index.length): fail(c"map counter indices must be consecutive", line)
		prof_entry* e = prof_entry_for(fields[2], fields[1], atoi(fields[6]), fields[3], fields[4], atoi(fields[5]))
		m.by_index.push(e)
	return m


# One raw dump: "index count" lines appended by lib/profile.w.
void prof_dump_apply(prof_map* m, char* path):
	list[char*] lines = file_read_lines(path)
	if (lines == 0): fail(c"cannot read dump", path)
	for char* line in lines:
		if (line[0] == 0): continue
		list[char*] fields = split(line)
		if (fields.length != 2): fail(c"malformed dump line", line)
		int index = atoi(fields[0])
		if ((index < 0) || (index >= m.by_index.length)): fail(c"dump counter index outside its map", line)
		prof_entry* e = m.by_index[index]
		e.count = e.count + atoi(fields[1])


# The value after "name=" in a "name=digits" field, or -1.
int prof_field_value(char* field, char* name):
	if (starts_with(field, name) == 0): return -1
	return atoi(field + strlen(name))


# An existing .wprof: its entries are merged by key.
void prof_profile_apply(char* path):
	list[char*] lines = file_read_lines(path)
	if (lines == 0): fail(c"cannot read profile", path)
	for char* line in lines:
		if ((line[0] == 0) || (line[0] == '#')): continue
		list[char*] fields = split(line)
		if (strcmp(fields[0], c"f") == 0):
			if (fields.length != 6): fail(c"malformed f line", line)
			int entries = prof_field_value(fields[5], c"entries=")
			if (entries < 0): fail(c"malformed f line", line)
			prof_entry* e = prof_entry_for(fields[1], c"f", 0, fields[2], fields[3], atoi(fields[4]))
			e.count = e.count + entries
		else if (strcmp(fields[0], c"l") == 0):
			if (fields.length != 7): fail(c"malformed l line", line)
			int head = prof_field_value(fields[5], c"head=")
			int iters = prof_field_value(fields[6], c"iters=")
			if ((head < 0) || (iters < 0)): fail(c"malformed l line", line)
			prof_entry* e = prof_entry_for(fields[1], c"l", head, fields[2], fields[3], atoi(fields[4]))
			e.count = e.count + iters
		else: fail(c"unknown profile line", line)


# --- output ------------------------------------------------------------

void prof_append_entry(string_builder* s, prof_entry* e):
	string_append(s, e.kind)
	string_append(s, c" ")
	string_append(s, e.hash)
	string_append(s, c" ")
	string_append(s, e.name)
	string_append(s, c" ")
	string_append(s, e.file)
	string_append(s, c" ")
	string_append_int(s, e.line)
	if (strcmp(e.kind, c"f") == 0):
		string_append(s, c" entries=")
	else:
		string_append(s, c" head=")
		string_append_int(s, e.ordinal)
		string_append(s, c" iters=")
	string_append_int(s, e.count)
	string_append(s, c"\n")


void prof_write(char* out_path, int zeros):
	string_builder* s = string_new()
	string_append(s, c"# wprof v1 from:")
	if (prof_inputs != 0):
		for char* input in prof_inputs:
			string_append(s, c" ")
			string_append(s, input)
	string_append(s, c"\n")
	if (prof_entries != 0):
		# Sorted by key: all of a function's lines together, f first,
		# then its loops by ordinal.
		list[char*] keys = new list[char*]
		for prof_entry* e in prof_entries: keys.push(prof_key(e.hash, e.kind, e.ordinal))
		keys.sort()
		for char* key in keys:
			prof_entry* e = prof_entries[prof_index[key]]
			if ((e.count != 0) || zeros): prof_append_entry(s, e)
	if (out_path == 0): out(s.data)
	else:
		if (file_write_text(out_path, s.data) == 0): fail(c"cannot write", out_path)
		chmod(out_path, 420)   # a data file, not the 0755 file_write_text creates
	string_free(s)


# --- subcommands -------------------------------------------------------

int wprof_merge(char** args, int argc):
	char* out_path = 0
	int zeros = 0
	prof_map* current = 0
	prof_inputs = new list[char*]
	int inputs = 0
	int i = 2
	while (i < argc):
		char* arg = args[i]
		if (strcmp(arg, c"-o") == 0):
			i = i + 1
			if (i >= argc): fail(c"-o needs a path", 0)
			out_path = args[i]
		else if (strcmp(arg, c"--zeros") == 0): zeros = 1
		else if (ends_with(arg, c".wprofmap")):
			current = prof_map_load(arg)
			prof_inputs.push(arg)
			inputs = inputs + 1
		else if (ends_with(arg, c".wprof")):
			prof_profile_apply(arg)
			prof_inputs.push(arg)
			inputs = inputs + 1
		else:
			if (current == 0): fail(c"a raw dump must follow its .wprofmap", arg)
			prof_dump_apply(current, arg)
			prof_inputs.push(arg)
			inputs = inputs + 1
		i = i + 1
	if (inputs == 0): fail(c"merge needs at least one .wprofmap or .wprof input", 0)
	prof_write(out_path, zeros)
	return 0


int wprof_clear(char** args, int argc):
	if (argc < 3): fail(c"clear needs at least one path", 0)
	for int i in range(2, argc):
		if (file_write_text(args[i], c"") == 0): fail(c"cannot truncate", args[i])
	return 0


# Everything a child writes to stdout, as one malloc'd string; the
# child's exit status in *status.
char* prof_capture(char* path, char** argv, char** env, int* status):
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_null
	opts.stdout_mode = process_pipe
	opts.env = env
	process* child = process_spawn(path, argv, opts)
	free(opts)
	if (child == 0): return 0
	string_builder* text = string_new()
	char* chunk = malloc(65536)
	int n = read(child.stdout_fd, chunk, 65536)
	while (n > 0):
		string_append_bytes(text, chunk, n)
		n = read(child.stdout_fd, chunk, 65536)
	free(chunk)
	close(child.stdout_fd)
	status[0] = process_wait(child)
	process_free(child)
	char* result = strclone(text.data)
	string_free(text)
	return result


# The "hash" of every function-like NDJSON record 'w defhash --closure'
# printed, added to hashes.
void prof_collect_defhashes(char* compiler, char* source, map[char*, int] hashes):
	char** argv = strv_new(6)
	strv_set(argv, 0, compiler)
	strv_set(argv, 1, c"defhash")
	strv_set(argv, 2, c"--closure")
	strv_set(argv, 3, c"--quiet")
	strv_set(argv, 4, source)
	int status = 0
	char* text = prof_capture(compiler, argv, 0, &status)
	free(cast(void*, argv))
	if (text == 0): fail(c"cannot run the compiler", compiler)
	if (status != 0): fail(c"defhash failed for", source)
	list[char*] lines = split(text, 10)
	for char* line in lines:
		int kind_at = index_of(line, c"\"kind\": \"")
		int hash_at = index_of(line, c"\"hash\": \"")
		if ((kind_at < 0) || (hash_at < 0)): continue
		char* kind = line + kind_at + 9
		if ((starts_with(kind, c"function\"") == 0) && (starts_with(kind, c"operator\"") == 0) && (starts_with(kind, c"generic_function\"") == 0)): continue
		int start = hash_at + 9
		int end = start
		while (((line[end] >= '0') && (line[end] <= '9')) || ((line[end] >= 'a') && (line[end] <= 'f'))): end = end + 1
		if (end - start != 64): continue
		char* hash = substring(line, start, end)
		if ((hash in hashes) == 0): hashes[hash] = 1
	free(text)


int wprof_stats(char** args, int argc):
	char* compiler = c"bin/wv2"
	char* profile = 0
	list[char*] sources = new list[char*]
	int i = 2
	while (i < argc):
		if (strcmp(args[i], c"--compiler") == 0):
			i = i + 1
			if (i >= argc): fail(c"--compiler needs a path", 0)
			compiler = args[i]
		else if (profile == 0): profile = args[i]
		else: sources.push(args[i])
		i = i + 1
	if ((profile == 0) || (sources.length == 0)): fail(c"stats needs <profile.wprof> <file.w>...", 0)
	prof_profile_apply(profile)
	map[char*, int] current = new map[char*, int]
	for char* source in sources: prof_collect_defhashes(compiler, source, current)
	# Distinct functions in the profile, and the entries under them.
	map[char*, int] seen = new map[char*, int]
	int functions = 0
	int functions_matched = 0
	int entries = 0
	int entries_matched = 0
	if (prof_entries != 0):
		for prof_entry* e in prof_entries:
			int matched = e.hash in current
			entries = entries + 1
			if (matched): entries_matched = entries_matched + 1
			if ((e.hash in seen) == 0):
				seen[e.hash] = 1
				functions = functions + 1
				if (matched): functions_matched = functions_matched + 1
	int percent = 0
	if (functions > 0): percent = functions_matched * 100 / functions
	string_builder* s = string_new()
	string_append(s, c"wprof stats: ")
	string_append(s, profile)
	string_append(s, c": ")
	string_append_int(s, functions_matched)
	string_append(s, c" of ")
	string_append_int(s, functions)
	string_append(s, c" functions match current defhashes (")
	string_append_int(s, percent)
	string_append(s, c"%), ")
	string_append_int(s, entries_matched)
	string_append(s, c" of ")
	string_append_int(s, entries)
	string_append(s, c" entries; ")
	string_append_int(s, current.length)
	string_append(s, c" current definitions\n")
	out(s.data)
	string_free(s)
	return 0


int prof_count_descending(prof_entry* a, prof_entry* b):
	if (a.count > b.count): return -1
	if (a.count < b.count): return 1
	return strcmp(a.name, b.name)


int wprof_top(char** args, int argc):
	int count = 20
	char* profile = 0
	char* only = 0
	int i = 2
	while (i < argc):
		if (strcmp(args[i], c"-n") == 0):
			i = i + 1
			if (i >= argc): fail(c"-n needs a count", 0)
			count = atoi(args[i])
		else if (strcmp(args[i], c"-f") == 0): only = c"f"
		else if (strcmp(args[i], c"-l") == 0): only = c"l"
		else: profile = args[i]
		i = i + 1
	if (profile == 0): fail(c"top needs <profile.wprof>", 0)
	prof_profile_apply(profile)
	if (prof_entries == 0): return 0
	for int pass in range(2):
		char* kind = c"f"
		if (pass == 1): kind = c"l"
		if ((only != 0) && (strcmp(only, kind) != 0)): continue
		list[prof_entry*] picked = new list[prof_entry*]
		for prof_entry* e in prof_entries:
			if (strcmp(e.kind, kind) == 0): picked.push(e)
		picked.sort_by(prof_count_descending)
		string_builder* s = string_new()
		if (pass == 0): string_append(s, c"functions by entries:\n")
		else: string_append(s, c"loops by head evaluations:\n")
		int shown = 0
		for prof_entry* e in picked:
			if (shown >= count): break
			string_append(s, c"  ")
			string_append_int(s, e.count)
			string_append(s, c"\t")
			string_append(s, e.name)
			if (pass == 1):
				string_append(s, c" loop ")
				string_append_int(s, e.ordinal)
			string_append(s, c"\t")
			string_append(s, e.file)
			string_append(s, c":")
			string_append_int(s, e.line)
			string_append(s, c"\n")
			shown = shown + 1
		out(s.data)
		string_free(s)
	return 0


# Compile and run one corpus program, collecting its dump under the
# group of its own map. Returns 1 when both steps succeeded.
int prof_corpus_one(char* compiler, char* arch, char* source, char* stem):
	char* binary = strjoin(stem, c".prof")
	char* raw = strjoin(stem, c".wprofraw")
	char** argv = strv_new(8)
	int n = 0
	strv_set(argv, n, compiler)
	n = n + 1
	if (arch != 0):
		strv_set(argv, n, arch)
		n = n + 1
	strv_set(argv, n, c"--quiet")
	n = n + 1
	strv_set(argv, n, c"--profile-generate")
	n = n + 1
	strv_set(argv, n, source)
	n = n + 1
	strv_set(argv, n, c"-o")
	n = n + 1
	strv_set(argv, n, binary)
	n = n + 1
	int status = 0
	char* text = prof_capture(compiler, argv, 0, &status)
	free(cast(void*, argv))
	if (text != 0): free(text)
	if (status != 0):
		err(c"wprof: corpus: compile failed, skipping ")
		err(source)
		err(c"\n")
		return 0
	file_write_text(raw, c"")
	char** run_argv = strv_new(2)
	strv_set(run_argv, 0, binary)
	char** env = env_copy_with(env_current(), c"W_PROFILE_OUT", raw)
	text = prof_capture(binary, run_argv, env, &status)
	free(cast(void*, run_argv))
	if (text != 0): free(text)
	if (status != 0):
		err(c"wprof: corpus: run failed, skipping ")
		err(source)
		err(c"\n")
		return 0
	char* map_path = strjoin(binary, c".wprofmap")
	prof_map* m = prof_map_load(map_path)
	prof_dump_apply(m, raw)
	prof_inputs.push(source)
	return 1


int wprof_corpus(char** args, int argc):
	char* out_path = 0
	char* compiler = c"bin/wv2"
	char* arch = 0
	char* dir = 0
	int i = 2
	while (i < argc):
		if (strcmp(args[i], c"-o") == 0):
			i = i + 1
			if (i >= argc): fail(c"-o needs a path", 0)
			out_path = args[i]
		else if (strcmp(args[i], c"--compiler") == 0):
			i = i + 1
			if (i >= argc): fail(c"--compiler needs a path", 0)
			compiler = args[i]
		else if (strcmp(args[i], c"--arch") == 0):
			i = i + 1
			if (i >= argc): fail(c"--arch needs a selector", 0)
			arch = args[i]
		else: dir = args[i]
		i = i + 1
	if (dir == 0): fail(c"corpus needs <dir>", 0)
	prof_inputs = new list[char*]
	list[char*] names = dir_names(dir)
	int ran = 0
	if (names == 0):
		err(c"wprof: corpus: no directory ")
		err(dir)
		err(c", writing an empty profile\n")
	else:
		for char* name in names:
			if (ends_with(name, c".w") == 0): continue
			char* source = strjoin(strjoin(dir, c"/"), name)
			char* stem = strjoin(c"bin/corpus_", substring(name, 0, strlen(name) - 2))
			ran = ran + prof_corpus_one(compiler, arch, source, stem)
	prof_write(out_path, 0)
	string_builder* s = string_new()
	string_append(s, c"wprof corpus: ")
	string_append_int(s, ran)
	string_append(s, c" program(s) profiled\n")
	err(s.data)
	string_free(s)
	return 0


void usage():
	err(c"usage: wprof merge [-o out.wprof] [--zeros] <x.wprofmap> <dump>... [<y.wprof>]...\n")
	err(c"       wprof stats [--compiler w] <profile.wprof> <file.w>...\n")
	err(c"       wprof top [-n count] [-f|-l] <profile.wprof>\n")
	err(c"       wprof clear <path>...\n")
	err(c"       wprof corpus [-o out.wprof] [--compiler w] [--arch sel] <dir>\n")
	exit(1)


int main(int argc, int argv):
	char** args = cast(char**, argv)
	if (argc < 2): usage()
	char* command = args[1]
	if (strcmp(command, c"merge") == 0): return wprof_merge(args, argc)
	if (strcmp(command, c"stats") == 0): return wprof_stats(args, argc)
	if (strcmp(command, c"top") == 0): return wprof_top(args, argc)
	if (strcmp(command, c"clear") == 0): return wprof_clear(args, argc)
	if (strcmp(command, c"corpus") == 0): return wprof_corpus(args, argc)
	usage()
	return 1
