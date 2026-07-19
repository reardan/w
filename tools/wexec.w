/*
wexec: the W-native build executor — the replacement for the old Makefile.

wexec reads a static JSON manifest (build.json by default) describing
build/test targets, resolves their dependency DAG depth-first, and runs
each target's steps as child processes via lib.process. It deliberately
knows nothing about W itself: the manifest spells out every command, so
porting a Makefile rule was a mechanical transcription and the executor
core stays small enough to trust.

Manifest shape:

{
	"dirs": ["bin"],
	"targets": [
		{
			"name": "hello",
			"deps": ["wv2"],
			"steps": [
				{"cmd": ["bin/wv2", "tests/hello.w", "-o", "bin/hello"]},
				{"cmd": ["bin/hello"], "expect_stdout": "hello, world!"}
			]
		}
	]
}

Step fields: "cmd" (argv, required; argv[0] is resolved against PATH
when it contains no slash), "stdin" (text piped to the child),
"expect_stdout" / "expect_stderr" (a substring — or array of
substrings — the captured stream must contain), "reject_stdout" /
"reject_stderr" (substring(s) that must NOT appear, the manifest's
version of "! grep -q"), "expect_fail" (the step must exit nonzero,
the manifest's version of Make's "! cmd"), "expect_status" (an exact
exit code), "stdout_file" / "stderr_file" (write the captured stream
to a path, replacing shell "> file" redirects), and "timeout_ms"
(0 = no timeout).

Every target runs at most once per invocation. Targets that declare
"inputs" (a list of files and directory prefixes ending in "/") are
cached by content hash: when the hash of the target definition, its
input files and its dependencies' keys matches the stamp left in
bin/.wexec_cache/ — and every declared "outputs" file exists — the
target is skipped. For a cacheable target whose steps compile W roots,
the roots' per-arch import closures ('bin/wv2 deps', cached in
bin/.wexec_deps_cache) replace the .w files found under input directory
prefixes, so a W edit invalidates exactly the targets whose closures
contain it (see the deps-driven cache keys section below). Targets
without "inputs" behave like make-style FORCE targets: requesting them
always runs them. A step's captured stdout/stderr is re-emitted after
the step finishes, so output is visible but not interleaved live.

Usage: wexec [-f manifest.json] [--list [--json]] [--explain-cache target]
             [--no-cache] [--keep-going] [--ordered-output] [-j N] target...

Direct-file UX (issue #323 stage 1): in place of a target name, wexec
also accepts a bare "<file>.w" or a "[selector] <file>.w" pair (e.g.
"x64 path/to/file.w") naming a W source instead of a manifest target.
When an existing target's own compile step already builds that file for
that selector, wexec runs that target exactly as if it had been named
directly. Otherwise wexec synthesizes a throwaway target: compile the
file to bin/<stem> (bin/<stem>_<selector> for a non-default selector),
then run the result when the file is a "*_test.w". The synthesized
target declares "inputs": [<file>], so it gets the same content-hash
(and, once bin/wv2 exists, deps-driven closure) caching as any other
cacheable target above — a repeat invocation with nothing changed is a
cache hit. See the "Direct-file UX" section further down for the
implementation.

A failed target normally stops all scheduling (fail-fast); the epilogue
then reports how many targets were never attempted. With --keep-going a
failure only poisons its dependents: independent subgraphs keep running,
dependents of a failed target are skipped, and a summary on stderr names
every failed and skipped target. Either way wexec exits nonzero when
anything failed.

Under -j > 1 the default scheduler still streams only the oldest
in-flight target live and holds later ones back until it is their turn,
so a target that finishes early can end up flushed immediately after an
unrelated target's failure with no separator between them — easy to
misread as one target's output. --ordered-output buffers each target's
whole step output (stdout and stderr, in step order) instead of
streaming any of it, and prints it as a single block, headed by a
"wexec: --- <target> ---" line, the moment that target finishes
(completion order, not start order). Default (streaming) output is
unaffected by the flag's existence.

Shared remote cache: when the environment variable W_CACHE_URL is set,
a target whose local cache misses tries a GET against that URL before
running its steps, and (only with W_CACHE_PUSH=1, what CI sets) PUTs
its bundle back after a successful run. With neither variable set this
is byte-for-byte the pre-existing behavior; see the "Shared remote
build cache" comment just above wexec_launch for the protocol and
bundle format.

Two introspection flags, both read-only (no steps run): "--list --json"
prints one NDJSON object per target — {"name", "step_count", "deps",
"compile_roots", "shells_out", "generate_exclude"} — instead of the
plain newline-separated names bare --list prints; bare --list is
unchanged. "--explain-cache <target>" prints, in human-readable form,
whether that target is cacheable and, when it isn't because some
dependency never stores a cache key of its own (see the deps-driven
cache keys section above and wexec_cache_key below — a dependency
without "inputs" is a FORCE target and disables caching for every
target downstream of it, silently, with no diagnostic), the specific
dependency and chain that breaks it.

A third, Linux-only introspection mode, "--trace <target> [--hermetic]"
(issue #251 Direction 2), runs the target's own steps under ptrace and
reports every file they successfully opened for reading against the
target's declared input set (the same "inputs" plus deps-driven
compile-root closures --explain-cache and the cache key above already
treat as this target's inputs) -- an audit surface that runs no build
step differently and changes nothing about a plain `wexec <target>`.
See tools/wexec_trace.w for the ptrace mechanism and its documented
noise filter.

Before running any requested target's steps through the ordinary
scheduler (wexec_execute), wexec takes an advisory single-writer lock on
its managed bin/ directory (bin/.wexec_lock, O_CREAT|O_EXCL, stale-pid
reclaim) so a second overlapping invocation in the same worktree fails
fast with a clear message instead of both processes writing/executing
the same bin/wv2. See the block comment above wexec_lock_file (just
before main) for the full design, including why wexec's own nested
test-harness invocations are exempt. "--list", "--explain-cache" and
"--trace" return before that point and never take the lock: the first
two run no steps at all, and --trace's own ptrace-wrapped step runner
(tools/wexec_trace.w) is a deliberately out-of-scope manual audit path,
not part of the ordinary build/test flow this lock protects.

Design notes: docs/projects/wexec.md
*/
import lib.lib
import lib.env
import lib.file
import lib.process
import lib.sha256
import lib.stream
import lib.utf8
import structures.string
import structures.json
import tools.__arch__.wexec_remote_http
import tools.wexec_trace


json_value* wexec_manifest
map[char*, json_value*] wexec_targets  # name -> json_value* of the target object
map[char*, int] wexec_states        # name -> 0 unvisited / 1 visiting / 2 collected
map[char*, char*] wexec_keys        # name -> char* cache key, for targets with "inputs"
map[char*, int] wexec_started       # name -> 1 once launched (or completed inline)
map[char*, int] wexec_finished      # name -> 1 once successfully finished
list[char*] wexec_names      # manifest order, for --list
list[char*] wexec_closure    # requested targets + deps, dependency order
int wexec_completed          # targets finished this invocation
int wexec_no_cache           # --no-cache: never skip cached targets
int wexec_keep_going         # --keep-going: schedule past failed targets
int wexec_ordered_output     # --ordered-output: buffer each target's output, print atomically in completion order
int wexec_jobs               # max targets in flight (-j), default nproc
map[char*, int] wexec_broken    # name -> 1 once failed or skipped (--keep-going)
list[char*] wexec_failed_list   # failed targets, in completion order
list[char*] wexec_skipped_list  # targets skipped behind a failed dependency
int wexec_lock_held             # 1 once *this* process created (and must remove) bin/.wexec_lock


int wexec_collect_closure(char* name);
void wexec_collect_dir(char* path, list[char*] files);


void wexec_error(char* message):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"wexec: error: ")
	stream_write_line(err, message)
	stream_flush(err)


# Error messages are built with f-strings and handed to char* consumers
# through cstr() (#146). The f-string result is caller-owned; on these
# failure paths the process is about to exit nonzero, so letting exit
# reclaim the bytes matches the ownership story in
# docs/projects/template_strings.md.
void wexec_error2(char* message, char* detail):
	wexec_error(cstr(f"{message}{detail}"))


void wexec_usage():
	wstream* err = stderr_writer()
	stream_write_line(err, c"usage: wexec [-f manifest.json] [--list [--json]] [--explain-cache target] [--no-cache] [--keep-going] [--ordered-output] [-j N] target...")
	stream_write_line(err, c"       wexec [-f manifest.json] ... [selector] <file>.w")
	stream_write_line(err, c"       wexec [-f manifest.json] --trace target [--hermetic]")
	stream_flush(err)


/* JSON field accessors tolerating absent keys. */

char* wexec_get_string(json_value* object, char* key):
	json_value* value = json_object_get(object, key)
	if (value == 0):
		return 0
	if (value.type != json_type_string()):
		return 0
	return value.string_value


int wexec_get_int(json_value* object, char* key, int missing):
	json_value* value = json_object_get(object, key)
	if (value == 0):
		return missing
	if (value.type != json_type_int()):
		return missing
	return value.int_value


int wexec_get_flag(json_value* object, char* key):
	json_value* value = json_object_get(object, key)
	if (value == 0):
		return 0
	if ((value.type == json_type_bool()) | (value.type == json_type_int())):
		return value.int_value != 0
	return 0


int wexec_str_contains(char* haystack, char* needle):
	int n = strlen(needle)
	if (n == 0):
		return 1
	int i = 0
	while (haystack[i] != 0):
		int j = 0
		while ((j < n) && (haystack[i + j] == needle[j])):
			j = j + 1
		if (j == n):
			return 1
		i = i + 1
	return 0


/* Content-hash caching.

A target that declares "inputs" gets a cache key: a SHA-256 hash (D3-1;
lib.sha256, see docs/projects/wexec.md) over its serialized definition,
its dependencies' cache keys and the contents of every input file
(directory entries ending in "/" are walked recursively). The key is
stamped into bin/.wexec_cache/<name> after a successful run; a matching
stamp plus existing "outputs" files lets the next invocation skip the
target. A target whose dependency has no cache key (a FORCE-style
target) is never cacheable, because a fresh dependency run may have
changed what this target consumes.

The digest widened from a 32-hex-char pair of rolling hashes to a
64-hex-char SHA-256 hex string, so a stamp file or bin/.wexec_deps_cache
"H " line written by the old format never equality-matches a freshly
computed key: it degrades to a plain cache miss (an ordinary rebuild),
never an error. */

struct wexec_hash:
	int* state          # 8 running 32-bit words: SHA-256 h[0..7]
	char* block          # 64-byte pending block, not yet compressed
	int block_len        # bytes buffered in block, 0..63
	int total_len        # total bytes hashed so far


# Streams bytes through lib.sha256's block compressor (sha256_block) 64
# bytes at a time, instead of buffering a target's whole definition plus
# every input file before hashing once. lib/sha256.w is seed-compiled
# and is not modified here — only its already-public building blocks
# (sha256_h0_table/sha256_be32/sha256_put_be32/sha256_mask32/
# sha256_block) are reused, mirroring what sha256()'s own tail handling
# does, applied incrementally instead of over one flat buffer.
void wexec_hash_init(wexec_hash* h):
	h.state = cast(int*, malloc(8 * __word_size__))
	char* h0 = sha256_h0_table()
	int i = 0
	while (i < 8):
		h.state[i] = sha256_be32(h0 + i * 4)
		i = i + 1
	h.block = malloc(64)
	h.block_len = 0
	h.total_len = 0


void wexec_hash_bytes(wexec_hash* h, char* data, int n):
	h.total_len = h.total_len + n
	int i = 0
	while (i < n):
		h.block[h.block_len] = data[i]
		h.block_len = h.block_len + 1
		if (h.block_len == 64):
			sha256_block(h.state, h.block)
			h.block_len = 0
		i = i + 1


# Strings never contain NUL, so a trailing 0 byte keeps consecutive
# strings from colliding with their concatenation.
void wexec_hash_cstr(wexec_hash* h, char* text):
	wexec_hash_bytes(h, text, strlen(text))
	char zero = 0
	wexec_hash_bytes(h, &zero, 1)


void wexec_hash_file(wexec_hash* h, char* path):
	int fd = open(path, 0, 0)
	if (fd < 0):
		wexec_hash_cstr(h, c"<missing input>")
		return
	char* buffer = malloc(4096)
	int n = read(fd, buffer, 4096)
	while (n > 0):
		wexec_hash_bytes(h, buffer, n)
		n = read(fd, buffer, 4096)
	free(buffer)
	close(fd)


void wexec_append_hex_byte(string_builder* s, int value):
	int hi = (value >> 4) & 15
	int lo = value & 15
	if (hi < 10):
		string_append_char(s, '0' + hi)
	else:
		string_append_char(s, 'a' + hi - 10)
	if (lo < 10):
		string_append_char(s, '0' + lo)
	else:
		string_append_char(s, 'a' + lo - 10)


# Finalize: pad the trailing partial block exactly as sha256()'s own tail
# handling does (0x80 terminator, zero pad, 64-bit big-endian bit
# length), compress it, then hex-encode all 32 digest bytes — 64 hex
# characters, twice the old two-int rolling hash's 32.
char* wexec_hash_hex(wexec_hash* h):
	char* tail = malloc(128)
	int j = 0
	while (j < 128):
		tail[j] = 0
		j = j + 1
	j = 0
	while (j < h.block_len):
		tail[j] = h.block[j]
		j = j + 1
	tail[h.block_len] = 128 /* 0x80 */
	int blocks = 1
	if (h.block_len >= 56):
		blocks = 2
	int bitlen_pos = blocks * 64 - 8
	sha256_put_be32(tail + bitlen_pos, (h.total_len >> 29) & sha256_mask32())
	sha256_put_be32(tail + bitlen_pos + 4, (h.total_len << 3) & sha256_mask32())
	sha256_block(h.state, tail)
	if (blocks == 2):
		sha256_block(h.state, tail + 64)
	free(tail)

	char* digest = malloc(32)
	int i = 0
	while (i < 8):
		sha256_put_be32(digest + i * 4, h.state[i])
		i = i + 1

	string_builder* s = string_new()
	i = 0
	while (i < 32):
		wexec_append_hex_byte(s, digest[i] & 255)
		i = i + 1
	free(digest)
	free(h.state)
	free(h.block)
	char* text = s.data
	free(s)
	return text


int wexec_load_uint16(char* p):
	return (p[0] & 255) + ((p[1] & 255) << 8)


# Recursively collect every regular file under path. Uses the classic
# getdents layout: d_reclen is 2 bytes after ino and off (one word each),
# the name follows it, and d_type sits in the record's last byte
# (4 = directory, 8 = regular file).
# On Windows, FindFirstFileA/FindNextFileA are used instead.
void wexec_collect_dir(char* path, list[char*] files):
	if (os_windows()):
		# WIN32_FIND_DATAA: dwFileAttributes(4)+3×FILETIME(24)+4×DWORD(16)+
		# cFileName[260]+cAlternateFileName[14] = 320 bytes.
		# cFileName is at offset 44; FILE_ATTRIBUTE_DIRECTORY = 0x10 = 16.
		char* find_data = malloc(320)
		string_builder* pat = string_new()
		string_append(pat, path)
		string_append(pat, c"/*")
		int handle = FindFirstFileA(pat.data, find_data)
		string_free(pat)
		if (handle != -1):
			while (1):
				char* name = find_data + 44
				int attrs = load_int32(find_data)
				if ((strcmp(name, c".") != 0) && (strcmp(name, c"..") != 0)):
					string_builder* child = string_new()
					string_append(child, path)
					string_append_char(child, '/')
					string_append(child, name)
					if (attrs & 16):
						wexec_collect_dir(child.data, files)
						string_free(child)
					else:
						char* owned = child.data
						free(child)
						files.push(owned)
				if (FindNextFileA(handle, find_data) == 0):
					break
			FindClose(handle)
		free(find_data)
		return
	# 65536 = O_DIRECTORY
	int fd = open(path, 65536, 0)
	if (fd < 0):
		return
	int buffer_size = 65536
	char* buffer = malloc(buffer_size)
	int n = getdents(fd, buffer, buffer_size)
	while (n > 0):
		int off = 0
		while (off < n):
			char* entry = buffer + off
			int reclen = wexec_load_uint16(entry + 2 * __word_size__)
			char* entry_name = entry + 2 * __word_size__ + 2
			int kind = entry[reclen - 1] & 255
			if ((strcmp(entry_name, c".") != 0) && (strcmp(entry_name, c"..") != 0)):
				string_builder* child = string_new()
				string_append(child, path)
				string_append(child, c"/")
				string_append(child, entry_name)
				if (kind == 4):
					wexec_collect_dir(child.data, files)
					string_free(child)
				else if (kind == 8):
					char* owned = child.data
					free(child)
					files.push(owned)
				else:
					string_free(child)
			off = off + reclen
		n = getdents(fd, buffer, buffer_size)
	free(buffer)
	close(fd)


# Insertion sort: getdents order depends on filesystem state, and the
# hash must not.
void wexec_sort_strings(list[char*] files):
	int i = 1
	while (i < files.length):
		char* value = files[i]
		int j = i - 1
		while ((j >= 0) && (strcmp(files[j], value) > 0)):
			files[j + 1] = files[j]
			j = j - 1
		files[j + 1] = value
		i = i + 1


# Every real manifest target name is a bare identifier, so this is a
# byte-identical no-op for them; it only starts mattering for the
# direct-file UX's synthesized names (below), which embed a source path
# and so may contain '/' -- escaped here rather than by nesting
# directories under bin/.wexec_cache/, so the stamp stays a flat file.
char* wexec_stamp_path(char* name):
	string_builder* s = string_new()
	string_append(s, c"bin/.wexec_cache/")
	int i = 0
	while (name[i] != 0):
		char c = name[i]
		if ((c == '/') || (c == ':') || (c == 92)):
			string_append_char(s, '_')
		else:
			string_append_char(s, c)
		i = i + 1
	char* path = s.data
	free(s)
	return path


/* Deps-driven cache keys (issue #251 Direction 1).

A target whose own steps compile W roots — 'bin/wv2 [selector] [flags]
<root>.w ... -o out' commands, or seed './w' compiles — is keyed on the
roots' transitive import closures, computed by shelling out to
'bin/wv2 deps [selector] <root>', instead of on the .w files found under
its declared "inputs" directory prefixes. Declared inputs still
contribute every explicitly listed file (seeds, scripts, run-time .w
fixtures) and every non-.w file found under directory prefixes (run-time
data like tests/asm/), so only the W-source over-approximation is
replaced by the exact per-root, per-arch closure. Targets without
"inputs" stay FORCE targets exactly as before: closures never make a
target cacheable that was not already opted in, because targets like
parser_generator_w_test depend on out-of-graph state (every tracked .w)
that no closure can see.

Closures are cached in bin/.wexec_deps_cache — the bin/.wtest_deps_cache
format with a leading target-selector column:

  R <arch> <root>
  H <combined content hash over the closure's (path, content) pairs>
  F <closure file> (one line per file, in deps output order)

An entry is reused while re-hashing every F file reproduces H. A root
that fails to compile is cached as

  X <arch> <root>
  H <content hash of the root file itself>

and retried once the root's own content changes; a target with a failed
root keeps the pre-closure key (declared inputs, .w files included), so
targets that compile intentionally-broken fixtures behave exactly as
before. Entries are validated lazily, only for roots the requested
targets actually compile; the cache file is rewritten after a run that
recomputed anything, preserving untouched entries verbatim. When bin/wv2
does not exist, closures are skipped entirely and every target keeps its
pre-closure key. */

struct wexec_deps_entry:
	char* arch          # selector word; "x86" for the default target
	char* root
	int failed          # 'X' record: the root did not compile
	int checked         # validated or recomputed during this run
	char* digest        # the H line value
	char* blob          # newline-guarded closure file list, 0 when failed


list[wexec_deps_entry*] wexec_deps_entries
map[char*, wexec_deps_entry*] wexec_deps_index   # "<arch> <root>" -> entry
map[char*, char*] wexec_file_hashes              # path -> content hash memo
int wexec_deps_loaded
int wexec_deps_dirty
int wexec_deps_probed
int wexec_deps_wv2_ok


# Content hash of one file, memoized. Missing files hash to a sentinel
# that can never match a stored digest, so deletions invalidate entries.
char* wexec_file_hash(char* path):
	if (wexec_file_hashes == 0):
		wexec_file_hashes = new map[char*, char*]
	char* cached = wexec_file_hashes.get(path, 0)
	if (cached != 0):
		return cached
	char* digest = c"<missing>"
	int fd = open(path, 0, 0)
	if (fd >= 0):
		wexec_hash h
		wexec_hash_init(&h)
		int buffer_size = 65536
		char* buffer = malloc(buffer_size)
		int n = read(fd, buffer, buffer_size)
		while (n > 0):
			wexec_hash_bytes(&h, buffer, n)
			n = read(fd, buffer, buffer_size)
		free(buffer)
		close(fd)
		digest = wexec_hash_hex(&h)
	wexec_file_hashes[path] = digest
	return digest


# Combined digest over (path, content hash) of every file in a closure
# blob, in order.
char* wexec_deps_digest(char* blob):
	wexec_hash h
	wexec_hash_init(&h)
	string_builder* line = string_new()
	int i = 0
	while (blob[i] != 0):
		if (blob[i] == 10):
			if (line.length > 0):
				wexec_hash_cstr(&h, line.data)
				wexec_hash_cstr(&h, wexec_file_hash(line.data))
				string_clear(line)
		else:
			string_append_char(line, blob[i])
		i = i + 1
	if (line.length > 0):
		wexec_hash_cstr(&h, line.data)
		wexec_hash_cstr(&h, wexec_file_hash(line.data))
	string_free(line)
	return wexec_hash_hex(&h)


# Closures need bin/wv2; without it (a manifest run before any build)
# every target keeps its pre-closure key.
int wexec_deps_usable():
	if (wexec_deps_probed == 0):
		wexec_deps_probed = 1
		int fd = open(c"bin/wv2", 0, 0)
		if (fd >= 0):
			close(fd)
			wexec_deps_wv2_ok = 1
	return wexec_deps_wv2_ok


int wexec_selector_word(char* word):
	if (strcmp(word, c"x64") == 0):
		return 1
	if (strcmp(word, c"arm64") == 0):
		return 1
	if (strcmp(word, c"arm64_darwin") == 0):
		return 1
	if (strcmp(word, c"win64") == 0):
		return 1
	return 0


char* wexec_deps_entry_key(char* arch, char* root):
	string_builder* s = string_new()
	string_append(s, arch)
	string_append_char(s, ' ')
	string_append(s, root)
	char* key = s.data
	free(s)
	return key


void wexec_deps_store(char* arch, char* root, wexec_deps_entry* entry):
	entry.arch = arch
	entry.root = root
	wexec_deps_entries.push(entry)
	char* key = wexec_deps_entry_key(arch, root)
	wexec_deps_index[key] = entry
	free(key)


# Finalize one parsed cache-file record. The record key is
# "<arch> <root>"; a record without the arch column (or a duplicate) is
# dropped, so caches written by older executors simply recompute.
void wexec_deps_load_entry(int kind, char* record, char* digest, string_builder* blob):
	if ((record == 0) || (digest == 0)):
		return
	int space = 0
	int i = 0
	while (record[i] != 0):
		if ((record[i] == ' ') && (space == 0)):
			space = i
		i = i + 1
	if (space == 0):
		return
	char* arch = strclone(record)
	arch[space] = 0
	char* root = strclone(record + space + 1)
	char* key = wexec_deps_entry_key(arch, root)
	wexec_deps_entry* existing = wexec_deps_index.get(key, 0)
	free(key)
	if (existing != 0):
		return
	wexec_deps_entry* entry = new wexec_deps_entry()
	entry.failed = kind == 2
	entry.checked = 0
	entry.digest = digest
	entry.blob = 0
	if (kind == 1):
		if (blob != 0):
			entry.blob = blob.data
	wexec_deps_store(arch, root, entry)


void wexec_deps_load():
	if (wexec_deps_loaded):
		return
	wexec_deps_loaded = 1
	wexec_deps_entries = new list[wexec_deps_entry*]
	wexec_deps_index = new map[char*, wexec_deps_entry*]
	char* text = file_read_text(c"bin/.wexec_deps_cache")
	if (text == 0):
		return
	int kind = 0
	char* record = 0
	char* digest = 0
	string_builder* blob = 0
	string_builder* line = string_new()
	int i = 0
	int at_end = 0
	while (at_end == 0):
		int c = text[i]
		if (c == 0):
			at_end = 1
		if ((c == 10) || (c == 0)):
			char* entry = line.data
			if (starts_with(entry, c"R ") | starts_with(entry, c"X ")):
				wexec_deps_load_entry(kind, record, digest, blob)
				kind = 1
				if (entry[0] == 'X'):
					kind = 2
				record = strclone(entry + 2)
				digest = 0
				blob = string_new()
				string_append_char(blob, 10)
			else if (starts_with(entry, c"H ")):
				digest = strclone(entry + 2)
			else if (starts_with(entry, c"F ")):
				if (blob != 0):
					string_append(blob, entry + 2)
					string_append_char(blob, 10)
			string_clear(line)
		else:
			string_append_char(line, c)
		i = i + 1
	wexec_deps_load_entry(kind, record, digest, blob)
	string_free(line)
	free(text)


void wexec_deps_save():
	if (wexec_deps_dirty == 0):
		return
	wexec_deps_dirty = 0
	string_builder* out = string_new()
	for wexec_deps_entry* entry in wexec_deps_entries:
		if (entry.failed):
			string_append(out, c"X ")
		else:
			string_append(out, c"R ")
		string_append(out, entry.arch)
		string_append_char(out, ' ')
		string_append(out, entry.root)
		string_append_char(out, 10)
		string_append(out, c"H ")
		string_append(out, entry.digest)
		string_append_char(out, 10)
		if (entry.blob != 0):
			string_builder* line = string_new()
			int j = 0
			while (entry.blob[j] != 0):
				if (entry.blob[j] == 10):
					if (line.length > 0):
						string_append(out, c"F ")
						string_append(out, line.data)
						string_append_char(out, 10)
						string_clear(line)
				else:
					string_append_char(line, entry.blob[j])
				j = j + 1
			string_free(line)
	mkdir(c"bin", 493)
	file_write_text(c"bin/.wexec_deps_cache", out.data)
	string_free(out)


# Run 'bin/wv2 deps [selector] <root>'; returns a newline-guarded closure
# blob, or 0 when the root does not compile for that target.
char* wexec_deps_run(char* arch, char* root):
	int is_default = strcmp(arch, c"x86") == 0
	int count = 4
	if (is_default):
		count = 3
	char** argv = strv_new(count)
	strv_set(argv, 0, c"bin/wv2")
	strv_set(argv, 1, c"deps")
	if (is_default):
		strv_set(argv, 2, root)
	else:
		strv_set(argv, 2, arch)
		strv_set(argv, 3, root)
	process_result* result = process_run(c"bin/wv2", argv, 0, 0, 120000)
	free(cast(char*, argv))
	if (result == 0):
		return 0
	if (result.status != 0):
		process_result_free(result)
		return 0
	string_builder* blob = string_new()
	string_append_char(blob, 10)
	string_append(blob, result.stdout_text)
	if (blob.data[blob.length - 1] != 10):
		string_append_char(blob, 10)
	process_result_free(result)
	char* text = blob.data
	free(blob)
	return text


# The closure entry for one (arch, root), validated against current file
# contents or recomputed. entry.failed marks a root that did not compile.
wexec_deps_entry* wexec_deps_lookup(char* arch, char* root):
	wexec_deps_load()
	char* key = wexec_deps_entry_key(arch, root)
	wexec_deps_entry* entry = wexec_deps_index.get(key, 0)
	free(key)
	if (entry != 0):
		if (entry.checked):
			return entry
		if (entry.failed):
			if (strcmp(wexec_file_hash(root), entry.digest) == 0):
				entry.checked = 1
				return entry
		else if (entry.blob != 0):
			char* digest = wexec_deps_digest(entry.blob)
			if (strcmp(digest, entry.digest) == 0):
				entry.checked = 1
				entry.digest = digest
				return entry
	char* blob = wexec_deps_run(arch, root)
	if (entry == 0):
		entry = new wexec_deps_entry()
		wexec_deps_store(strclone(arch), strclone(root), entry)
	entry.checked = 1
	wexec_deps_dirty = 1
	if (blob == 0):
		entry.failed = 1
		entry.blob = 0
		entry.digest = wexec_file_hash(entry.root)
	else:
		entry.failed = 0
		entry.blob = blob
		entry.digest = wexec_deps_digest(blob)
	return entry


# W compile roots of the target's own steps: 'bin/wv2 [selector] [flags]
# <root>.w ... -o out' (or seed './w' compiles), as parallel (arch, root)
# lists. Dependency targets' roots are not collected — their closures are
# already chained in through the dependency cache keys.
void wexec_deps_collect_roots(json_value* target, list[char*] archs, list[char*] roots):
	json_value* steps = json_object_get(target, c"steps")
	if (steps == 0):
		return
	if (steps.type != json_type_array()):
		return
	int s = 0
	while (s < json_array_length(steps)):
		json_value* step = json_array_get(steps, s)
		s = s + 1
		if (step.type != json_type_object()):
			continue
		json_value* cmd = json_object_get(step, c"cmd")
		if (cmd == 0):
			continue
		if (cmd.type != json_type_array()):
			continue
		int n = json_array_length(cmd)
		if (n < 2):
			continue
		json_value* program = json_array_get(cmd, 0)
		if (program.type != json_type_string()):
			continue
		if ((strcmp(program.string_value, c"bin/wv2") != 0) && (strcmp(program.string_value, c"./w") != 0)):
			continue
		int has_output = 0
		int i = 1
		while (i < n):
			json_value* piece = json_array_get(cmd, i)
			if (piece.type == json_type_string()):
				if (strcmp(piece.string_value, c"-o") == 0):
					has_output = 1
			i = i + 1
		if (has_output == 0):
			continue
		char* arch = c"x86"
		json_value* first = json_array_get(cmd, 1)
		if (first.type == json_type_string()):
			if (wexec_selector_word(first.string_value)):
				arch = first.string_value
		i = 1
		while (i < n):
			json_value* piece = json_array_get(cmd, i)
			if (piece.type == json_type_string()):
				char* element = piece.string_value
				if (strcmp(element, c"-o") == 0):
					i = i + 2
					continue
				if (ends_with(element, c".w")):
					archs.push(arch)
					roots.push(element)
			i = i + 1


/* Direct-file UX (issue #323 stage 1).

'wexec [selector] <file>.w' (in place of a target name list) runs the
manifest target that already compiles <file>.w as its own root -- found
by scanning every target's own compile roots exactly like
wexec_deps_collect_roots does above, since "the target whose compile
root is that file" is precisely the (arch, root) pairs that function
extracts -- or, when no target compiles it, synthesizes a throwaway
compile(+run, for a *_test.w file) target for it. The synthesized
target declares "inputs": [<file>], so it goes through the exact same
content-hash (and, once bin/wv2 exists, deps-driven closure) caching as
any other declared-"inputs" target above: a repeat invocation with
nothing changed is a cache hit. Nothing here touches the loaded
manifest's own targets; the synthesized target is added to
wexec_targets/wexec_names for this process only. */

# The first manifest target (in manifest order) whose own compile steps
# build 'path' for 'arch', or 0. "Own" mirrors wexec_deps_collect_roots:
# a dependency's compile roots don't count, only the target's own.
char* wexec_find_target_for_root(char* arch, char* path):
	for char* name in wexec_names:
		json_value* target = wexec_targets.get(name, 0)
		if (target == 0):
			continue
		list[char*] archs = new list[char*]
		list[char*] roots = new list[char*]
		wexec_deps_collect_roots(target, archs, roots)
		int i = 0
		while (i < roots.length):
			if ((strcmp(archs[i], arch) == 0) && (strcmp(roots[i], path) == 0)):
				return name
			i = i + 1
	return 0


char* wexec_adhoc_basename(char* path):
	int i = 0
	int last = 0
	while (path[i] != 0):
		if (path[i] == '/'):
			last = i + 1
		i = i + 1
	return path + last


# The first (length - n) characters of text, as a fresh string.
char* wexec_adhoc_strip_suffix(char* text, int n):
	int keep = strlen(text) - n
	string_builder* s = string_new()
	int i = 0
	while (i < keep):
		string_append_char(s, text[i])
		i = i + 1
	char* out = s.data
	free(s)
	return out


# bin/<stem> for the default (x86) arch; a per-arch suffix otherwise, so
# e.g. 'foo_test.w' and 'x64 foo_test.w' never clobber each other's
# output (and so their cache entries stay independent). win64 keeps the
# ".exe" extension the rest of the win64 tooling expects.
char* wexec_adhoc_binary_path(char* arch, char* stem):
	if (strcmp(arch, c"x86") == 0):
		return cstr(f"bin/{stem}")
	if (strcmp(arch, c"win64") == 0):
		return cstr(f"bin/{stem}_win64.exe")
	return cstr(f"bin/{stem}_{arch}")


# The synthesized target's own "name": the bare path for the default
# arch (so "wexec: target <path>" reads naturally), "<arch>:<path>"
# otherwise. Never collides with a real manifest target name, which is
# always a bare identifier with neither '/' nor ':'.
char* wexec_adhoc_target_name(char* arch, char* path):
	if (strcmp(arch, c"x86") == 0):
		return path
	return cstr(f"{arch}:{path}")


json_value* wexec_make_adhoc_target(char* name, char* arch, char* path, char* binary):
	json_value* target = json_object()
	json_object_set(target, c"name", json_string(name))
	json_value* deps = json_array()
	json_array_push(deps, json_string(c"wv2"))
	json_object_set(target, c"deps", deps)
	json_value* inputs = json_array()
	json_array_push(inputs, json_string(path))
	json_object_set(target, c"inputs", inputs)
	json_value* outputs = json_array()
	json_array_push(outputs, json_string(binary))
	json_object_set(target, c"outputs", outputs)

	json_value* compile_cmd = json_array()
	json_array_push(compile_cmd, json_string(c"bin/wv2"))
	if (strcmp(arch, c"x86") != 0):
		json_array_push(compile_cmd, json_string(arch))
	json_array_push(compile_cmd, json_string(path))
	json_array_push(compile_cmd, json_string(c"-o"))
	json_array_push(compile_cmd, json_string(binary))
	json_value* compile_step = json_object()
	json_object_set(compile_step, c"cmd", compile_cmd)
	json_value* steps = json_array()
	json_array_push(steps, compile_step)

	# arm64_darwin never gets a run step -- no runner executes Mach-O on
	# Linux, mirroring wbuildgen's compile-only X_darwin twins; every
	# other arch runs the binary straight or through the same wrapper
	# tools/wbuildgen.w's wbg_make_target uses for its conventional
	# twins.
	if (ends_with(path, c"_test.w") && (strcmp(arch, c"arm64_darwin") != 0)):
		json_value* run_cmd = json_array()
		if (strcmp(arch, c"arm64") == 0):
			json_array_push(run_cmd, json_string(c"sh"))
			json_array_push(run_cmd, json_string(c"tools/run_arm64.sh"))
		else if (strcmp(arch, c"win64") == 0):
			json_array_push(run_cmd, json_string(c"wine"))
		json_array_push(run_cmd, json_string(binary))
		json_value* run_step = json_object()
		json_object_set(run_step, c"cmd", run_cmd)
		json_array_push(steps, run_step)

	json_object_set(target, c"steps", steps)
	return target


# Resolves "[<arch>] <path>.w" to a target name registered in
# wexec_targets -- an existing manifest target, or a freshly synthesized
# one -- or returns 0 after reporting an error (a missing file, or an
# absurd name collision). A leading "./" is tolerated, since shells and
# tab completion often add one.
char* wexec_resolve_direct_file(char* arch, char* path):
	if (starts_with(path, c"./")):
		path = path + 2
	int fd = open(path, 0, 0)
	if (fd < 0):
		wexec_error2(c"no such file: ", path)
		return 0
	close(fd)

	char* found = wexec_find_target_for_root(arch, path)
	if (found != 0):
		return found

	char* stem = wexec_adhoc_strip_suffix(wexec_adhoc_basename(path), 2)
	char* binary = wexec_adhoc_binary_path(arch, stem)
	char* name = wexec_adhoc_target_name(arch, path)
	if (name in wexec_targets):
		wexec_error2(c"ad-hoc target collides with an existing manifest target: ", name)
		return 0
	json_value* target = wexec_make_adhoc_target(name, arch, path, binary)
	wexec_targets[name] = target
	wexec_names.push(name)
	return name


# Returns the target's cache key, or 0 when the target is not cacheable
# (no "inputs" declared, or a dependency without a key of its own).
# Dependencies must have finished before this is called.
char* wexec_cache_key(char* name, json_value* target):
	json_value* inputs = json_object_get(target, c"inputs")
	if (inputs == 0):
		return 0
	if (inputs.type != json_type_array()):
		return 0

	wexec_hash h
	wexec_hash_init(&h)
	char* definition = json_stringify(target)
	wexec_hash_cstr(&h, definition)
	free(definition)

	json_value* deps = json_object_get(target, c"deps")
	if (deps != 0):
		if (deps.type == json_type_array()):
			int i = 0
			while (i < json_array_length(deps)):
				json_value* dep = json_array_get(deps, i)
				if (dep.type == json_type_string()):
					char* dep_key = wexec_keys.get(dep.string_value, 0)
					if (dep_key == 0):
						return 0
					wexec_hash_cstr(&h, dep_key)
				i = i + 1

	# Deps-driven keys: hash each compile root's import closure. A root
	# that fails 'bin/wv2 deps' disables closure keying for the whole
	# target (fixture targets compile intentionally-broken sources), and
	# the declared inputs below then contribute their .w files as before.
	list[char*] root_archs = new list[char*]
	list[char*] root_paths = new list[char*]
	if (wexec_deps_usable()):
		wexec_deps_collect_roots(target, root_archs, root_paths)
	int closures = root_paths.length > 0
	int r = 0
	while (r < root_paths.length):
		wexec_deps_entry* closure_entry = wexec_deps_lookup(root_archs[r], root_paths[r])
		if (closure_entry.failed):
			closures = 0
		r = r + 1
	if (closures):
		r = 0
		while (r < root_paths.length):
			wexec_deps_entry* keyed_entry = wexec_deps_lookup(root_archs[r], root_paths[r])
			wexec_hash_cstr(&h, root_archs[r])
			wexec_hash_cstr(&h, root_paths[r])
			wexec_hash_cstr(&h, keyed_entry.digest)
			r = r + 1

	list[char*] files = new list[char*]
	int i = 0
	while (i < json_array_length(inputs)):
		json_value* entry = json_array_get(inputs, i)
		if (entry.type == json_type_string()):
			char* path = entry.string_value
			int n = strlen(path)
			if ((n > 0) && (path[n - 1] == '/')):
				char* dir = strclone(path)
				dir[n - 1] = 0
				if (closures):
					# The closure hashes above cover the W sources
					# exactly; a directory prefix now contributes only
					# its non-.w files (run-time data, fixtures).
					list[char*] walked = new list[char*]
					wexec_collect_dir(dir, walked)
					for char* found in walked:
						if (ends_with(found, c".w") == 0):
							files.push(found)
				else:
					wexec_collect_dir(dir, files)
				free(dir)
			else:
				files.push(path)
		i = i + 1
	wexec_sort_strings(files)
	for char* path in files:
		wexec_hash_cstr(&h, path)
		wexec_hash_file(&h, path)
	return wexec_hash_hex(&h)


# A cache hit needs a matching stamp and every declared output present.
int wexec_cache_fresh(char* name, char* key, json_value* target):
	char* stamp_path = wexec_stamp_path(name)
	char* stamp = file_read_text(stamp_path)
	free(stamp_path)
	if (stamp == 0):
		return 0
	int same = strcmp(stamp, key) == 0
	free(stamp)
	if (same == 0):
		return 0
	json_value* outputs = json_object_get(target, c"outputs")
	if (outputs != 0):
		if (outputs.type == json_type_array()):
			int i = 0
			while (i < json_array_length(outputs)):
				json_value* output = json_array_get(outputs, i)
				if (output.type == json_type_string()):
					int fd = open(output.string_value, 0, 0)
					if (fd < 0):
						return 0
					close(fd)
				i = i + 1
	return 1


void wexec_cache_store(char* name, char* key):
	# Failure (usually EEXIST) is fine, like wexec_make_dirs.
	mkdir(c"bin", 493)
	mkdir(c"bin/.wexec_cache", 493)
	char* stamp_path = wexec_stamp_path(name)
	file_write_text(stamp_path, key)
	free(stamp_path)


/* --explain-cache <target> (docs/projects/ai_tooling_next_steps.md,
"Test selection" bullet 2): a static, read-only explanation of whether a
target can ever get a cache key, without running anything. It mirrors
wexec_cache_key's own gates rather than calling it, because the real
function needs its dependencies' wexec_keys entries already populated
by a run in progress; --explain-cache instead walks the "deps" graph
itself, treating a target as (recursively) cacheable exactly when it
declares "inputs" and every dependency, transitively, does too — which
is precisely the condition wexec_cache_key checks one dependency layer
at a time via wexec_keys.get(dep, 0). The documented trap: a dependency
with no "inputs" of its own is a FORCE target, never stores a key, and
so silently disables caching for everything downstream of it, with no
diagnostic at build time. */

int wexec_target_declares_inputs(json_value* target):
	json_value* inputs = json_object_get(target, c"inputs")
	if (inputs == 0):
		return 0
	if (inputs.type != json_type_array()):
		return 0
	return 1


int wexec_target_dep_count(json_value* target):
	json_value* deps = json_object_get(target, c"deps")
	if (deps == 0):
		return 0
	if (deps.type != json_type_array()):
		return 0
	return json_array_length(deps)


void wexec_reverse_strings(list[char*] items):
	int i = 0
	int j = items.length - 1
	while (i < j):
		char* tmp = items[i]
		items[i] = items[j]
		items[j] = tmp
		i = i + 1
		j = j - 1


# Shortest-path BFS over the "deps" graph reachable from 'start' (whose
# own "inputs" gate the caller already checked). Returns 1 and fills
# chain_out with [start, ..., broken] — the dependency path down to the
# first target that does not declare "inputs" — when one is reachable;
# returns 0, leaving chain_out empty, when every transitively reachable
# dependency declares "inputs" of its own. An unknown dependency name
# (a manifest bug reported elsewhere, at actual scheduling time) is
# skipped rather than treated as broken.
int wexec_explain_find_broken(char* start, list[char*] chain_out):
	map[char*, char*] parent = new map[char*, char*]
	map[char*, int] seen = new map[char*, int]
	list[char*] queue = new list[char*]
	seen[start] = 1
	queue.push(start)
	int qi = 0
	while (qi < queue.length):
		char* cur = queue[qi]
		qi = qi + 1
		json_value* cur_target = wexec_targets.get(cur, 0)
		if (cur_target == 0):
			continue
		if (strcmp(cur, start) != 0):
			if (wexec_target_declares_inputs(cur_target) == 0):
				char* node = cur
				while (node != 0):
					chain_out.push(node)
					node = parent.get(node, 0)
				wexec_reverse_strings(chain_out)
				return 1
		json_value* deps = json_object_get(cur_target, c"deps")
		if (deps != 0):
			if (deps.type == json_type_array()):
				int i = 0
				while (i < json_array_length(deps)):
					json_value* dep = json_array_get(deps, i)
					if (dep.type == json_type_string()):
						if (seen.get(dep.string_value, 0) == 0):
							seen[dep.string_value] = 1
							parent[dep.string_value] = cur
							queue.push(dep.string_value)
					i = i + 1
	return 0


int wexec_explain_cache(char* name):
	json_value* target = wexec_targets.get(name, 0)
	if (target == 0):
		wexec_error2(c"unknown target ", name)
		return 1
	wstream* out = stdout_writer()
	stream_write_cstr(out, c"wexec: explain-cache ")
	stream_write_line(out, name)
	if (wexec_target_declares_inputs(target) == 0):
		stream_write_line(out, c"  declares \"inputs\": no")
		stream_write_line(out, c"  not cacheable: FORCE-style target (no \"inputs\"); every request runs it")
		stream_flush(out)
		return 0
	stream_write_line(out, c"  declares \"inputs\": yes")
	if (wexec_target_dep_count(target) == 0):
		stream_write_line(out, c"  no declared \"deps\": nothing else can block caching")
		stream_write_line(out, c"  cacheable: yes (still needs a matching stamp and existing \"outputs\" files to actually skip a run)")
		stream_flush(out)
		return 0
	list[char*] path = new list[char*]
	if (wexec_explain_find_broken(name, path)):
		string_builder* chain = string_new()
		int i = 0
		while (i < path.length):
			if (i > 0):
				string_append(chain, c" -> ")
			string_append(chain, path[i])
			i = i + 1
		stream_write_cstr(out, c"  dependency chain: ")
		stream_write_line(out, chain.data)
		string_free(chain)
		char* broken = path[path.length - 1]
		stream_write_cstr(out, c"  not cacheable: dependency '")
		stream_write_cstr(out, broken)
		stream_write_line(out, c"' declares no \"inputs\" of its own (FORCE-style), so it never stores a cache key — every target downstream of it silently loses caching too, with no diagnostic at build time")
		stream_flush(out)
		return 0
	stream_write_line(out, c"  every declared dependency (transitively) declares \"inputs\" and can store a cache key")
	stream_write_line(out, c"  cacheable: yes (still needs a matching stamp and existing \"outputs\" files to actually skip a run)")
	stream_flush(out)
	return 0


# Windows: manifest commands name Linux-style binaries ("bin/wv2");
# resolve to the ".exe" sibling when the bare path does not exist.
# CreateProcessA does not append ".exe" to path-containing names.
char* wexec_resolve_exe_suffix(char* name):
	int fd = open(name, 0, 0)
	if (fd >= 0):
		close(fd)
		return name
	string_builder* exe = string_new()
	string_append(exe, name)
	string_append(exe, c".exe")
	fd = open(exe.data, 0, 0)
	if (fd >= 0):
		close(fd)
		char* resolved = exe.data
		free(exe)
		return resolved
	string_free(exe)
	return name


# execve does no PATH lookup, so commands like "cmp" or "grep" must be
# resolved here. Anything with a slash is used as-is (on Windows, after
# the ".exe" fallback).
char* wexec_resolve_program(char* name):
	int win = os_windows()
	int i = 0
	while (name[i] != 0):
		if ((name[i] == '/') || (win && (name[i] == 92))):
			if (win):
				return wexec_resolve_exe_suffix(name)
			return name
		i = i + 1
	char* path = env_get(c"PATH")
	# On Windows the PATH separator is ';' and executables need '.exe'
	char path_sep = ':'
	if (win):
		path_sep = ';'
	if (path == 0):
		if (win):
			path = c"C:/Windows/System32"
		else:
			path = c"/usr/bin:/bin"
	string_builder* candidate = string_new()
	int p = 0
	int at_end = 0
	while (at_end == 0):
		string_clear(candidate)
		while ((path[p] != path_sep) && (path[p] != 0)):
			string_append_char(candidate, path[p])
			p = p + 1
		if (path[p] == 0):
			at_end = 1
		else:
			p = p + 1
		if (candidate.length > 0):
			string_append_char(candidate, '/')
			string_append(candidate, name)
			if (win):
				# Try both with and without .exe suffix
				string_append(candidate, c".exe")
			int fd = open(candidate.data, 0, 0)
			if (fd >= 0):
				close(fd)
				return candidate.data
			if (win):
				# Also try without .exe (script-style names)
				candidate.data[candidate.length - 4] = 0
				candidate.length = candidate.length - 4
				fd = open(candidate.data, 0, 0)
				if (fd >= 0):
					close(fd)
					return candidate.data
	string_free(candidate)
	return name


void wexec_echo_command(char** argv, int count):
	string_builder* line = string_new()
	string_append(line, c"$")
	int i = 0
	while (i < count):
		string_append(line, c" ")
		string_append(line, strv_get(argv, i))
		i = i + 1
	wstream* out = stdout_writer()
	stream_write_line(out, line.data)
	stream_flush(out)
	string_free(line)


void wexec_step_error(char* target_name, int step_index, char* message):
	wexec_error(cstr(f"target '{target_name}' step {step_index + 1}: {message}"))


# Re-emit the child's captured streams so build output stays visible.
void wexec_emit_output(process_result* result):
	if (result.stdout_length > 0):
		write(1, result.stdout_text, result.stdout_length)
	if (result.stderr_length > 0):
		write(2, result.stderr_text, result.stderr_length)


# A step that declares its command must fail ("expect_fail", or a
# nonzero "expect_status"). Such a command's failure output is fixture
# material the manifest author planned for, not a diagnostic — re-emitting
# it makes a green run look broken (wexec_test's intentional-failure
# fixtures print "wexec: error: ..." into a passing suite log).
int wexec_step_expects_failure(json_value* step):
	if (wexec_get_flag(step, c"expect_fail")):
		return 1
	json_value* wanted = json_object_get(step, c"expect_status")
	if (wanted != 0):
		if (wanted.type == json_type_int()):
			if (wanted.int_value != 0):
				return 1
	return 0


# Printed in place of the captured streams when an expected failure
# happened as declared, so the log states the failure was intentional.
void wexec_note_expected_failure(process_result* result):
	string_builder* line = string_new()
	string_append(line, c"wexec: expected failure (exit status ")
	string_append_int(line, result.status)
	if ((result.stdout_length > 0) || (result.stderr_length > 0)):
		string_append(line, c", output suppressed")
	string_append(line, c")")
	wstream* out = stdout_writer()
	stream_write_line(out, line.data)
	stream_flush(out)
	string_free(line)


int wexec_check_status(char* target_name, int step_index, json_value* step, process_result* result):
	if (result.status < 0):
		wexec_step_error(target_name, step_index, c"command timed out or could not be waited on")
		return 1
	json_value* wanted = json_object_get(step, c"expect_status")
	if (wanted != 0):
		if (wanted.type != json_type_int()):
			wexec_step_error(target_name, step_index, c"\"expect_status\" must be an integer")
			return 1
		if (result.status != wanted.int_value):
			wexec_step_error(target_name, step_index, cstr(f"command exited {result.status}, expected status {wanted.int_value}"))
			return 1
		return 0
	if (wexec_get_flag(step, c"expect_fail")):
		if (result.status == 0):
			wexec_step_error(target_name, step_index, c"command was expected to fail but exited 0")
			return 1
		return 0
	if (result.status != 0):
		wexec_step_error(target_name, step_index, cstr(f"command failed with exit status {result.status}"))
		return 1
	return 0


# reject != 0 inverts the check: the needle must be absent.
int wexec_check_needle(char* target_name, int step_index, char* stream_name, char* text, char* needle, int reject):
	int found = wexec_str_contains(text, needle)
	if (reject == 0):
		if (found):
			return 0
	else:
		if (found == 0):
			return 0
	string_builder* s = string_new()
	string_append(s, c"expected ")
	string_append(s, stream_name)
	if (reject):
		string_append(s, c" to not contain: ")
	else:
		string_append(s, c" to contain: ")
	string_append(s, needle)
	wexec_step_error(target_name, step_index, s.data)
	string_free(s)
	return 1


# An expectation field may be a single substring or an array of them.
int wexec_check_expectation(char* target_name, int step_index, json_value* step, char* key, char* stream_name, char* text, int reject):
	json_value* value = json_object_get(step, key)
	if (value == 0):
		return 0
	if (value.type == json_type_string()):
		return wexec_check_needle(target_name, step_index, stream_name, text, value.string_value, reject)
	if (value.type != json_type_array()):
		wexec_error2(c"expectation must be a string or array of strings: ", key)
		return 1
	int i = 0
	while (i < json_array_length(value)):
		json_value* entry = json_array_get(value, i)
		if (entry.type != json_type_string()):
			wexec_error2(c"expectation array entries must be strings: ", key)
			return 1
		if (wexec_check_needle(target_name, step_index, stream_name, text, entry.string_value, reject)):
			return 1
		i = i + 1
	return 0


# "stdout_file" / "stderr_file": save the captured stream to a path,
# the manifest's version of a "> file" shell redirect.
int wexec_write_capture(char* target_name, int step_index, json_value* step, char* key, char* data, int length):
	char* path = wexec_get_string(step, key)
	if (path == 0):
		return 0
	# 577 = O_WRONLY | O_CREAT | O_TRUNC, 420 = rw-r--r--
	int fd = open(path, 577, 420)
	if (fd < 0):
		wexec_step_error(target_name, step_index, c"cannot write capture file")
		return 1
	int written = 0
	if (length > 0):
		written = write(fd, data, length)
	close(fd)
	if (written < length):
		wexec_step_error(target_name, step_index, c"short write to capture file")
		return 1
	return 0


int wexec_run_step(char* target_name, int step_index, json_value* step):
	if (step.type != json_type_object()):
		wexec_step_error(target_name, step_index, c"step is not a JSON object")
		return 1
	json_value* cmd = json_object_get(step, c"cmd")
	if (cmd == 0):
		wexec_step_error(target_name, step_index, c"step has no \"cmd\"")
		return 1
	if (cmd.type != json_type_array()):
		wexec_step_error(target_name, step_index, c"\"cmd\" is not an array")
		return 1
	int count = json_array_length(cmd)
	if (count < 1):
		wexec_step_error(target_name, step_index, c"\"cmd\" is empty")
		return 1

	# The win64 self-host targets prefix their PE binaries with "wine" so
	# the one manifest works on Linux; on Windows the binaries run
	# natively, so a leading "wine" token is dropped.
	int skip = 0
	if (os_windows() && (count > 1)):
		json_value* first = json_array_get(cmd, 0)
		if (first.type == json_type_string()):
			if (strcmp(first.string_value, c"wine") == 0):
				skip = 1
	count = count - skip

	char** argv = strv_new(count)
	int i = 0
	while (i < count):
		json_value* piece = json_array_get(cmd, i + skip)
		if (piece.type != json_type_string()):
			wexec_step_error(target_name, step_index, c"\"cmd\" entries must be strings")
			free(cast(char*, argv))
			return 1
		strv_set(argv, i, piece.string_value)
		i = i + 1

	wexec_echo_command(argv, count)
	char* program = wexec_resolve_program(strv_get(argv, 0))
	char* stdin_text = wexec_get_string(step, c"stdin")
	int timeout_ms = wexec_get_int(step, c"timeout_ms", 0)
	process_result* result = process_run(program, argv, 0, stdin_text, timeout_ms)
	free(cast(char*, argv))
	if (result == 0):
		wexec_step_error(target_name, step_index, c"failed to spawn command")
		return 1

	# An expected failure that passes every check hides its captured
	# streams behind a one-line marker; everything else re-emits them
	# up front as before (and an expected failure that misses a check
	# re-emits them after the error, for debugging).
	int expects_failure = wexec_step_expects_failure(step)
	if (expects_failure == 0):
		wexec_emit_output(result)
	int failed = wexec_write_capture(target_name, step_index, step, c"stdout_file", result.stdout_text, result.stdout_length)
	if (failed == 0):
		failed = wexec_write_capture(target_name, step_index, step, c"stderr_file", result.stderr_text, result.stderr_length)
	if (failed == 0):
		failed = wexec_check_status(target_name, step_index, step, result)
	if (failed == 0):
		failed = wexec_check_expectation(target_name, step_index, step, c"expect_stdout", c"stdout", result.stdout_text, 0)
	if (failed == 0):
		failed = wexec_check_expectation(target_name, step_index, step, c"expect_stderr", c"stderr", result.stderr_text, 0)
	if (failed == 0):
		failed = wexec_check_expectation(target_name, step_index, step, c"reject_stdout", c"stdout", result.stdout_text, 1)
	if (failed == 0):
		failed = wexec_check_expectation(target_name, step_index, step, c"reject_stderr", c"stderr", result.stderr_text, 1)
	if (expects_failure):
		if (failed):
			wexec_emit_output(result)
		else:
			wexec_note_expected_failure(result)
	process_result_free(result)
	return failed


/* The scheduler.

Targets run as concurrently forked copies of wexec itself: the child
redirects its stdout/stderr into pipes and runs the target's steps with
the ordinary sequential machinery, so everything a target prints stays
attributable to it. The parent polls every worker's pipes, buffers
output, and prints each target's output in start order (the oldest
in-flight worker streams live, later ones are held back until it
finishes), so parallel logs never interleave. Cache keys are computed
and stamps written by the parent only; a cache hit completes a target
without forking. The first failure stops new launches, in-flight
targets are drained, the epilogue counts the targets never attempted,
and the run exits 1 — make without -k. Under --keep-going (make -k)
a failure only marks its dependents broken: they are skipped, every
independent target still runs, and the epilogue names each failed and
skipped target before the run exits 1. */

# Depth-first closure collection: validates deps, diagnoses unknown
# targets and cycles, and appends every reachable target in dependency
# order (the serial execution order) to wexec_closure.
int wexec_collect_closure(char* name):
	int state = wexec_states.get(name, 0)
	if (state == 2):
		return 0
	if (state == 1):
		wexec_error2(c"dependency cycle involving target ", name)
		return 1
	json_value* target = wexec_targets.get(name, 0)
	if (target == 0):
		wexec_error2(c"unknown target ", name)
		return 1
	wexec_states[name] = 1
	json_value* deps = json_object_get(target, c"deps")
	if (deps != 0):
		if (deps.type != json_type_array()):
			wexec_error2(c"\"deps\" is not an array in target ", name)
			return 1
		int i = 0
		while (i < json_array_length(deps)):
			json_value* dep = json_array_get(deps, i)
			if (dep.type != json_type_string()):
				wexec_error2(c"\"deps\" entries must be strings in target ", name)
				return 1
			if (wexec_collect_closure(dep.string_value)):
				return 1
			i = i + 1
	wexec_states[name] = 2
	wexec_closure.push(name)
	return 0


int wexec_deps_finished(char* name):
	json_value* target = wexec_targets.get(name, 0)
	json_value* deps = json_object_get(target, c"deps")
	if (deps == 0):
		return 1
	int i = 0
	while (i < json_array_length(deps)):
		json_value* dep = json_array_get(deps, i)
		if (wexec_finished.get(dep.string_value, 0) == 0):
			return 0
		i = i + 1
	return 1


# --keep-going: a target whose dependency failed (or was itself skipped
# behind a failure) can never build. Deps were validated as strings when
# the closure was collected.
int wexec_deps_broken(char* name):
	json_value* target = wexec_targets.get(name, 0)
	json_value* deps = json_object_get(target, c"deps")
	if (deps == 0):
		return 0
	int i = 0
	while (i < json_array_length(deps)):
		json_value* dep = json_array_get(deps, i)
		if (wexec_broken.get(dep.string_value, 0)):
			return 1
		i = i + 1
	return 0


void wexec_print_target_header(char* name, char* suffix):
	wstream* out = stdout_writer()
	stream_write_cstr(out, c"wexec: target ")
	stream_write_cstr(out, name)
	stream_write_line(out, suffix)
	stream_flush(out)


int wexec_run_steps(char* name, json_value* target):
	json_value* steps = json_object_get(target, c"steps")
	if (steps == 0):
		return 0
	if (steps.type != json_type_array()):
		wexec_error2(c"\"steps\" is not an array in target ", name)
		return 1
	int i = 0
	while (i < json_array_length(steps)):
		if (wexec_run_step(name, i, json_array_get(steps, i))):
			return 1
		i = i + 1
	return 0


struct wexec_worker:
	char* name
	char* key            # cache key to stamp on success, or 0
	int pid
	int stdout_fd        # -1 once EOF
	int stderr_fd
	process_capture* out_buffer
	process_capture* err_buffer
	int out_printed      # bytes already written through to our stdout
	int err_printed
	int done


void wexec_mark_finished(char* name, char* key):
	if (key != 0):
		wexec_cache_store(name, key)
	wexec_finished[name] = 1
	wexec_completed = wexec_completed + 1


/* Shared remote build cache (issue #251 Direction 3, D3-2): a dumb
content-addressed HTTP read-through cache layered on top of the local
bin/.wexec_cache stamp above. Every code path below is gated on
wexec_cache_url() (the W_CACHE_URL env var) being set, and the push
half additionally on W_CACHE_PUSH=1 (what CI sets; a plain developer
checkout only ever reads) -- with neither set, wexec_cache_url() is a
single cheap env_get() and nothing else here ever runs, so the
env-unset path is byte-for-byte the pre-existing local-cache-only
behavior. That invariant is the whole point: a cache outage, a wrong
URL, or the feature being off entirely must never be able to break a
build, only slow it back down to "as if this feature didn't exist".

Protocol: GET/PUT <W_CACHE_URL>/objects/<first 2 hex>/<remaining 62
hex>, keyed on the same SHA-256 hex wexec_cache_key already computes
for the target's local stamp -- the loose-object path layout
libs/extras/vcs/cas.w's on-disk store uses (cas_object_path), so a
server backed by that module (see tests/wexec_remote_cache_test.w's
fixture server) can serve GET/PUT with no translation between the wire
path and its own store layout. A GET miss is any non-200 response
(canonically 404); any transport-level failure (DNS, connect, timeout,
TLS, ...) is also just a miss, but the first one per process
additionally prints one "remote cache unreachable" warning to stderr
-- worth knowing about once, not worth a line per target. PUT
failures warn the same way and are otherwise ignored: a push is
best-effort, and the target already succeeded locally either way.

Only targets that declare a non-empty "outputs" array participate
(wexec_target_has_outputs): a run-only target (a test whose value is
the run itself, not a file) has nothing to serialize into a bundle or
restore a skip against, so it is never looked up or pushed.

Bundle format (the GET response / PUT request body): a small
length-prefixed archive of the target's declared "outputs" files,
binary safe throughout (paths and file bytes are copied by explicit
length, never NUL/strlen-scanned) --

  "WBUN1\n"              magic + format version
  "<count>\n"            decimal file count
  per file, in "outputs" order:
    "<path length>\n"
    <path length> bytes  the output path exactly as declared in the
                         manifest (e.g. "bin/wv2")
    "<content length>\n"
    <content length> bytes   the file's exact contents

Timeouts are short (wexec_cache_timeout_ms(), a few seconds): a
misconfigured or dead cache must fail fast, not stall the build. */

char* wexec_cache_url_value
int wexec_cache_url_loaded
int wexec_remote_warned


# Memoized W_CACHE_URL (0 when unset or empty -- the "cache disabled"
# state every caller in this section checks first).
char* wexec_cache_url():
	if (wexec_cache_url_loaded == 0):
		wexec_cache_url_loaded = 1
		char* raw = env_get(c"W_CACHE_URL")
		if (raw != 0):
			if (raw[0] != 0):
				wexec_cache_url_value = raw
	return wexec_cache_url_value


int wexec_cache_push_enabled():
	char* raw = env_get(c"W_CACHE_PUSH")
	if (raw == 0):
		return 0
	return strcmp(raw, c"1") == 0


int wexec_cache_timeout_ms():
	return 3000


# One warning line per process, the first time the remote cache proves
# unreachable (a transport failure or a corrupt bundle -- not a plain
# 404 miss); silent after that.
void wexec_remote_warn(char* detail):
	if (wexec_remote_warned):
		return
	wexec_remote_warned = 1
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"wexec: warning: remote cache unreachable (")
	stream_write_cstr(err, detail)
	stream_write_line(err, c"); building locally")
	stream_flush(err)


int wexec_target_has_outputs(json_value* target):
	json_value* outputs = json_object_get(target, c"outputs")
	if (outputs == 0):
		return 0
	if (outputs.type != json_type_array()):
		return 0
	return json_array_length(outputs) > 0


# "<base>/objects/<first 2 hex>/<remaining 62 hex>" -- cas.w's loose
# object path, built against a caller-supplied base URL (one trailing
# slash tolerated).
char* wexec_cache_object_url(char* base, char* key):
	string_builder* s = string_new()
	string_append(s, base)
	if (s.length > 0):
		if (s.data[s.length - 1] == '/'):
			s.length = s.length - 1
			s.data[s.length] = 0
	string_append(s, c"/objects/")
	string_append_char(s, key[0])
	string_append_char(s, key[1])
	string_append_char(s, '/')
	string_append(s, key + 2)
	char* url = s.data
	free(s)
	return url


# Exact-byte copy: length bytes at data+pos, NUL-terminated for
# convenience only. Never strlen/substring-based -- bundle payloads are
# arbitrary binary and may contain embedded NUL bytes.
char* wexec_bundle_slice(char* data, int pos, int length):
	char* out = malloc(length + 1)
	int i = 0
	while (i < length):
		out[i] = data[pos + i]
		i = i + 1
	out[length] = 0
	return out


int wexec_bundle_check_magic(char* data, int length, int* pos):
	char* magic = c"WBUN1\n"
	int n = strlen(magic)
	if ((length - *pos) < n):
		return 0
	int i = 0
	while (i < n):
		if (data[*pos + i] != magic[i]):
			return 0
		i = i + 1
	*pos = *pos + n
	return 1


# A decimal integer line ("<digits>\n"); advances *pos past the
# newline. Returns -1 on any framing error (no digits, no terminator,
# run off the end) instead of trusting a malformed/truncated bundle.
int wexec_bundle_read_uint(char* data, int length, int* pos):
	int p = *pos
	int value = 0
	int digits = 0
	while ((p < length) && (data[p] >= '0') && (data[p] <= '9')):
		value = value * 10 + (data[p] - '0')
		digits = digits + 1
		p = p + 1
	if ((digits == 0) || (p >= length) || (data[p] != 10)):
		return -1
	*pos = p + 1
	return value


int wexec_bundle_write_file(char* path, char* data, int length):
	# 577 = O_WRONLY | O_CREAT | O_TRUNC, 420 = rw-r--r--
	int fd = open(path, 577, 420)
	if (fd < 0):
		return 0
	int written = 0
	if (length > 0):
		written = write(fd, data, length)
	close(fd)
	return written >= length


# Unpacks a bundle onto disk, writing each entry straight to its
# declared output path. Returns 1 on a fully valid, fully written
# bundle; any framing error or write failure aborts and returns 0 --
# the caller treats that exactly like a cache miss and falls back to
# building the target locally (partial writes from an aborted unpack
# are harmless: the target's normal steps will overwrite them).
int wexec_bundle_unpack(char* data, int length):
	int pos = 0
	if (wexec_bundle_check_magic(data, length, &pos) == 0):
		return 0
	int count = wexec_bundle_read_uint(data, length, &pos)
	if (count < 0):
		return 0
	int i = 0
	while (i < count):
		int path_len = wexec_bundle_read_uint(data, length, &pos)
		if (path_len <= 0):
			return 0
		if ((pos + path_len) > length):
			return 0
		char* path = wexec_bundle_slice(data, pos, path_len)
		pos = pos + path_len
		int content_len = wexec_bundle_read_uint(data, length, &pos)
		if (content_len < 0):
			free(path)
			return 0
		if ((pos + content_len) > length):
			free(path)
			return 0
		int wrote_ok = wexec_bundle_write_file(path, data + pos, content_len)
		free(path)
		if (wrote_ok == 0):
			return 0
		pos = pos + content_len
		i = i + 1
	return 1


# Whole-file read that tracks the exact byte length (unlike
# lib.file's file_read_text, whose caller only gets a NUL-terminated
# char* -- an output file's bytes may contain embedded NULs).
char* wexec_read_file_bytes(char* path, int* out_len):
	wstream* in = stream_open_read(path)
	if (in == 0):
		return 0
	string_builder* contents = string_new()
	stream_read_all(in, contents)
	stream_close(in)
	*out_len = contents.length
	char* data = contents.data
	free(contents)
	return data


# Serializes a target's declared "outputs" into a bundle (see the
# format above). Returns 0 (nothing to push) when "outputs" is
# missing/empty or any listed file cannot be read -- a target that
# just ran should always have its outputs present, but a push is
# best-effort and never worth failing the build over.
char* wexec_bundle_build(json_value* target, int* out_len):
	json_value* outputs = json_object_get(target, c"outputs")
	if (outputs == 0):
		return 0
	if (outputs.type != json_type_array()):
		return 0
	int n = json_array_length(outputs)
	if (n == 0):
		return 0
	list[char*] paths = new list[char*]
	list[char*] blobs = new list[char*]
	list[int] sizes = new list[int]
	int i = 0
	int ok = 1
	while ((i < n) && ok):
		json_value* entry = json_array_get(outputs, i)
		if (entry.type != json_type_string()):
			ok = 0
		else:
			int flen = 0
			char* data = wexec_read_file_bytes(entry.string_value, &flen)
			if (data == 0):
				ok = 0
			else:
				paths.push(entry.string_value)
				blobs.push(data)
				sizes.push(flen)
		i = i + 1
	if (ok == 0):
		for char* blob in blobs:
			free(blob)
		return 0
	string_builder* s = string_new()
	string_append(s, c"WBUN1\n")
	string_append_int(s, paths.length)
	string_append_char(s, 10)
	i = 0
	while (i < paths.length):
		char* path = paths[i]
		string_append_int(s, strlen(path))
		string_append_char(s, 10)
		string_append(s, path)
		string_append_int(s, sizes[i])
		string_append_char(s, 10)
		string_append_bytes(s, blobs[i], sizes[i])
		free(blobs[i])
		i = i + 1
	*out_len = s.length
	char* text = s.data
	free(s)
	return text


# GET <url>/objects/<key>; on a 200 with a bundle that unpacks cleanly,
# the target's outputs now exist on disk exactly as if it had just
# run. Returns 1 on a restored hit, 0 for a miss (404, any other
# status, a transport failure, or a corrupt bundle) -- the caller
# always falls back to a normal local build on 0. The actual HTTP call
# is tools/__arch__/<arch>/wexec_remote_http.w's wexec_remote_http_get
# (see that file for why this indirection exists -- win64 support).
int wexec_cache_remote_fetch(char* url, char* key):
	char* full = wexec_cache_object_url(url, key)
	int status = 0
	char* body = 0
	int body_len = 0
	char* error = 0
	int ok = 0
	if (wexec_remote_http_get(full, wexec_cache_timeout_ms(), &status, &body, &body_len, &error)):
		if (status == 200):
			ok = wexec_bundle_unpack(body, body_len)
			if (ok == 0):
				wexec_remote_warn(c"corrupt bundle")
		if (body != 0):
			free(body)
	else:
		wexec_remote_warn(error)
	free(full)
	return ok


# PUT <url>/objects/<key> with the target's bundle. Best-effort: any
# failure (nothing to read, transport, non-2xx) only warns (once) and
# never affects the target's already-successful local result. The
# actual HTTP call is wexec_remote_http_put (see wexec_cache_remote_fetch).
void wexec_cache_remote_push(char* url, char* key, json_value* target):
	int length = 0
	char* bundle = wexec_bundle_build(target, &length)
	if (bundle == 0):
		return
	char* full = wexec_cache_object_url(url, key)
	char* error = 0
	if (wexec_remote_http_put(full, bundle, length, wexec_cache_timeout_ms(), &error) == 0):
		wexec_remote_warn(error)
	free(full)
	free(bundle)


# Attempted from wexec_launch right after a local cache miss: eligible
# (W_CACHE_URL set, target declares "outputs") and a successful GET
# completes the target exactly like a local cache hit, just under a
# different log suffix. Returns 1 when the target was completed this
# way (the caller returns immediately, same as a local hit); 0 means
# proceed to the normal fork-and-run path.
int wexec_cache_remote_try(char* name, char* key, json_value* target):
	char* url = wexec_cache_url()
	if (url == 0):
		return 0
	if (wexec_target_has_outputs(target) == 0):
		return 0
	if (wexec_cache_remote_fetch(url, key) == 0):
		return 0
	wexec_print_target_header(name, c" (remote cache)")
	wexec_cache_store(name, key)
	wexec_finished[name] = 1
	wexec_completed = wexec_completed + 1
	return 1


# Called after a worker target finishes successfully: pushes the
# target's bundle when W_CACHE_PUSH=1 (what CI sets). A no-op whenever
# push is off, the target isn't cacheable, or it declares no outputs --
# the common developer-checkout case, so this is a single flag check
# in the fast path.
void wexec_cache_remote_push_if_enabled(char* name, char* key):
	if (key == 0):
		return
	if (wexec_cache_push_enabled() == 0):
		return
	char* url = wexec_cache_url()
	if (url == 0):
		return
	json_value* target = wexec_targets.get(name, 0)
	if (target == 0):
		return
	if (wexec_target_has_outputs(target) == 0):
		return
	wexec_cache_remote_push(url, key, target)


# Launch one target. Returns 0 when the target completed inline (cache
# hit or no steps), 1 when a worker was forked, -1 on spawn failure.
int wexec_launch(char* name, list[wexec_worker*] workers):
	json_value* target = wexec_targets.get(name, 0)
	char* key = wexec_cache_key(name, target)
	if (key != 0):
		wexec_keys[name] = key
		if (wexec_no_cache == 0):
			if (wexec_cache_fresh(name, key, target)):
				wexec_print_target_header(name, c" (cached)")
				wexec_finished[name] = 1
				wexec_completed = wexec_completed + 1
				return 0
			if (wexec_cache_remote_try(name, key, target)):
				return 0
	json_value* steps = json_object_get(target, c"steps")
	if (steps == 0):
		# Aggregate target: nothing to fork.
		wexec_print_target_header(name, c"")
		wexec_mark_finished(name, key)
		return 0

	int out_read = -1
	int out_write = -1
	int err_read = -1
	int err_write = -1
	if (process_make_pipe(&out_read, &out_write) < 0):
		wexec_error2(c"cannot create pipes for target ", name)
		return -1
	if (process_make_pipe(&err_read, &err_write) < 0):
		close(out_read)
		close(out_write)
		wexec_error2(c"cannot create pipes for target ", name)
		return -1
	int pid = fork()
	if (pid < 0):
		close(out_read)
		close(out_write)
		close(err_read)
		close(err_write)
		wexec_error2(c"cannot fork worker for target ", name)
		return -1
	if (pid == 0):
		# Worker: everything we print belongs to this target.
		close(out_read)
		close(err_read)
		process_redirect(out_write, 1)
		process_redirect(err_write, 2)
		wexec_print_target_header(name, c"")
		exit(wexec_run_steps(name, target))
	close(out_write)
	close(err_write)

	wexec_worker* w = new wexec_worker()
	w.name = name
	w.key = key
	w.pid = pid
	w.stdout_fd = out_read
	w.stderr_fd = err_read
	w.out_buffer = new process_capture()
	w.err_buffer = new process_capture()
	process_capture_init(w.out_buffer)
	process_capture_init(w.err_buffer)
	w.out_printed = 0
	w.err_printed = 0
	w.done = 0
	workers.push(w)
	return 1


# Write through any buffered output the worker has not printed yet.
# Only the oldest unfinished worker streams live; the rest are flushed
# when they reach the head of the start-order queue.
void wexec_worker_flush(wexec_worker* w):
	if (w.out_buffer.length > w.out_printed):
		write(1, w.out_buffer.data + w.out_printed, w.out_buffer.length - w.out_printed)
		w.out_printed = w.out_buffer.length
	if (w.err_buffer.length > w.err_printed):
		write(2, w.err_buffer.data + w.err_printed, w.err_buffer.length - w.err_printed)
		w.err_printed = w.err_buffer.length


# --ordered-output: print a worker's whole captured stdout/stderr as one
# block, headed by a grep-friendly marker line, instead of the
# progressive start-order streaming wexec_worker_flush does. Called once
# per worker, right after it is reaped, so blocks come out in completion
# order and a target's own lines can never have another target's lines
# spliced between them: nothing else runs between these writes, since
# the scheduler is single-threaded.
void wexec_worker_emit_block(wexec_worker* w):
	wstream* out = stdout_writer()
	stream_write_cstr(out, c"wexec: --- ")
	stream_write_cstr(out, w.name)
	stream_write_line(out, c" ---")
	stream_flush(out)
	if (w.out_buffer.length > 0):
		write(1, w.out_buffer.data, w.out_buffer.length)
	if (w.err_buffer.length > 0):
		write(2, w.err_buffer.data, w.err_buffer.length)


# One read per poll wakeup; returns 1 when the pipe reached EOF.
int wexec_worker_drain(int fd, process_capture* buffer):
	return process_capture_read(buffer, fd) <= 0


# --keep-going epilogue: name every failed and skipped target, then the
# counts, so lost coverage is visible at the bottom of a long run.
void wexec_report_keep_going(int total):
	wstream* err = stderr_writer()
	for char* name in wexec_failed_list:
		stream_write_cstr(err, c"wexec: failed: ")
		stream_write_line(err, name)
	for char* name in wexec_skipped_list:
		stream_write_cstr(err, c"wexec: skipped: ")
		stream_write_cstr(err, name)
		stream_write_line(err, c" (dependency failed)")
	string_builder* s = string_new()
	string_append(s, c"wexec: keep-going: ")
	string_append_int(s, wexec_failed_list.length)
	string_append(s, c" failed, ")
	string_append_int(s, wexec_skipped_list.length)
	string_append(s, c" skipped, ")
	string_append_int(s, wexec_completed)
	string_append(s, c" succeeded (of ")
	string_append_int(s, total)
	string_append(s, c" targets)")
	stream_write_line(err, s.data)
	stream_flush(err)
	string_free(s)


# Fail-fast epilogue: say how much of the run was never attempted, so
# one broken target cannot silently cancel the rest of an umbrella run.
# Silent when the failure was the last target scheduled.
void wexec_report_stopped_early(int total, int finished):
	if (finished >= total):
		return
	string_builder* s = string_new()
	string_append(s, c"wexec: stopped early after failure: ")
	string_append_int(s, total - finished)
	string_append(s, c" of ")
	string_append_int(s, total)
	string_append(s, c" targets not attempted")
	wstream* err = stderr_writer()
	stream_write_line(err, s.data)
	stream_flush(err)
	string_free(s)


void wexec_report_failures(int total, int finished):
	if (wexec_keep_going):
		wexec_report_keep_going(total)
	else:
		wexec_report_stopped_early(total, finished)


# Drive every requested target (and its dependency closure) to
# completion with up to wexec_jobs targets in flight. Returns 0 when
# everything succeeded.
int wexec_execute(list[char*] requested):
	for char* name in requested:
		if (wexec_collect_closure(name)):
			return 1

	int total = wexec_closure.length
	list[wexec_worker*] workers = new list[wexec_worker*]
	int head = 0       # first worker whose output is not fully printed
	int running = 0
	int finished = 0
	int failed = 0
	char* poll_fds = malloc(2 * wexec_jobs * 8 + 16)

	while (finished < total):
		# Launch phase: start every ready target, oldest first. Inline
		# completions (cache hits, aggregates) can ready more targets,
		# so repeat until a full scan launches nothing.
		int launched_any = 1
		while (((failed == 0) || wexec_keep_going) && launched_any):
			launched_any = 0
			int t = 0
			while ((t < total) && (running < wexec_jobs)):
				char* name = wexec_closure[t]
				if (wexec_started.get(name, 0) == 0):
					if (wexec_keep_going && wexec_deps_broken(name)):
						# A dependency failed: this target can never
						# build. Record the skip and count it finished
						# so independent subgraphs keep the run alive.
						wexec_started[name] = 1
						wexec_broken[name] = 1
						wexec_skipped_list.push(name)
						finished = finished + 1
						launched_any = 1
					else if (wexec_deps_finished(name)):
						wexec_started[name] = 1
						int outcome = wexec_launch(name, workers)
						if (outcome < 0):
							failed = 1
							if (wexec_keep_going):
								# A spawn failure counts as the target
								# failing; dependents skip via broken.
								wexec_broken[name] = 1
								wexec_failed_list.push(name)
								finished = finished + 1
								launched_any = 1
						else if (outcome == 0):
							finished = finished + 1
							launched_any = 1
						else:
							running = running + 1
				t = t + 1

		if (running == 0):
			# Nothing in flight: done, or blocked behind a failure.
			if (finished < total):
				failed = 1
			if (failed):
				# Print whatever buffered output is left, in order.
				# --ordered-output already emitted every reaped worker's
				# block at reap time, so there is nothing left to flush.
				if (wexec_ordered_output == 0):
					while (head < workers.length):
						wexec_worker_flush(workers[head])
						head = head + 1
				free(poll_fds)
				wexec_report_failures(total, finished)
				return 1
			free(poll_fds)
			return 0

		# Collect the open pipe fds of every unfinished worker.
		int nfds = 0
		int i = head
		while (i < workers.length):
			wexec_worker* w = workers[i]
			if (w.done == 0):
				if (w.stdout_fd >= 0):
					process_pollfd_set(poll_fds, nfds, w.stdout_fd, 1)
					nfds = nfds + 1
				if (w.stderr_fd >= 0):
					process_pollfd_set(poll_fds, nfds, w.stderr_fd, 1)
					nfds = nfds + 1
			i = i + 1
		if (nfds > 0):
			# Bounded wait so reaps of pipe-less workers still happen.
			poll(cast(int*, poll_fds), nfds, 100)
		else:
			process_sleep_ms(2)

		# Drain readable pipes (walking the same fd order the poll set
		# was built in) and reap workers whose pipes have both closed.
		int slot = 0
		i = head
		while (i < workers.length):
			wexec_worker* w = workers[i]
			if (w.done == 0):
				if (w.stdout_fd >= 0):
					if (process_pollfd_revents(poll_fds, slot) != 0):
						if (wexec_worker_drain(w.stdout_fd, w.out_buffer)):
							close(w.stdout_fd)
							w.stdout_fd = -1
					slot = slot + 1
				if (w.stderr_fd >= 0):
					if (process_pollfd_revents(poll_fds, slot) != 0):
						if (wexec_worker_drain(w.stderr_fd, w.err_buffer)):
							close(w.stderr_fd)
							w.stderr_fd = -1
					slot = slot + 1
				if ((w.stdout_fd < 0) && (w.stderr_fd < 0)):
					int status = 0
					int reaped = wait4(w.pid, &status, 0, 0)
					w.done = 1
					running = running - 1
					finished = finished + 1
					int decoded = process_decode_status(status)
					if (reaped < 0):
						decoded = 1
					if (decoded != 0):
						failed = 1
						if (wexec_keep_going):
							# Poison dependents so they are skipped
							# instead of waiting forever.
							wexec_broken[w.name] = 1
							wexec_failed_list.push(w.name)
					else:
						wexec_mark_finished(w.name, w.key)
						wexec_cache_remote_push_if_enabled(w.name, w.key)
					if (wexec_ordered_output):
						# Print this worker's whole block now, in
						# completion order, instead of waiting for its
						# turn in the start-order queue below.
						wexec_worker_emit_block(w)
			i = i + 1

		# Print phase: stream the head worker live and retire every
		# finished worker at the front of the start-order queue.
		# --ordered-output already emitted every worker's block above,
		# atomically, at the moment it finished, so this queue-ordered
		# live-streaming path is skipped entirely under the flag.
		if (wexec_ordered_output == 0):
			while ((head < workers.length) && workers[head].done):
				wexec_worker_flush(workers[head])
				head = head + 1
			if (head < workers.length):
				wexec_worker_flush(workers[head])

	free(poll_fds)
	if (failed):
		wexec_report_failures(total, finished)
		return 1
	return 0


void wexec_make_dirs():
	json_value* dirs = json_object_get(wexec_manifest, c"dirs")
	if (dirs == 0):
		return
	if (dirs.type != json_type_array()):
		return
	int i = 0
	while (i < json_array_length(dirs)):
		json_value* dir = json_array_get(dirs, i)
		if (dir.type == json_type_string()):
			# Failure (usually EEXIST) is fine; a truly missing
			# directory surfaces when a step tries to use it.
			mkdir(dir.string_value, 493)
		i = i + 1


int wexec_load_manifest(char* path):
	char* text = file_read_text(path)
	if (text == 0):
		wexec_error2(c"cannot read manifest ", path)
		return 1
	wexec_manifest = json_parse(text)
	free(text)
	if (wexec_manifest == 0):
		wexec_error2(c"manifest is not valid JSON: ", path)
		return 1
	if (wexec_manifest.type != json_type_object()):
		wexec_error2(c"manifest root must be a JSON object: ", path)
		return 1
	json_value* targets = json_object_get(wexec_manifest, c"targets")
	if (targets == 0):
		wexec_error2(c"manifest has no \"targets\" array: ", path)
		return 1
	if (targets.type != json_type_array()):
		wexec_error2(c"\"targets\" must be an array: ", path)
		return 1

	wexec_targets = new map[char*, json_value*]
	wexec_states = new map[char*, int]
	wexec_keys = new map[char*, char*]
	wexec_started = new map[char*, int]
	wexec_finished = new map[char*, int]
	wexec_names = new list[char*]
	wexec_closure = new list[char*]
	wexec_broken = new map[char*, int]
	wexec_failed_list = new list[char*]
	wexec_skipped_list = new list[char*]
	int i = 0
	while (i < json_array_length(targets)):
		json_value* target = json_array_get(targets, i)
		if (target.type != json_type_object()):
			wexec_error2(c"every target must be a JSON object: ", path)
			return 1
		char* name = wexec_get_string(target, c"name")
		if (name == 0):
			wexec_error2(c"target without a \"name\" string: ", path)
			return 1
		if (name in wexec_targets):
			wexec_error2(c"duplicate target ", name)
			return 1
		wexec_targets[name] = target
		wexec_names.push(name)
		i = i + 1
	wexec_make_dirs()
	return 0


void wexec_list_targets():
	wstream* out = stdout_writer()
	for char* name in wexec_names:
		stream_write_line(out, name)
	stream_flush(out)


/* --list --json (docs/projects/ai_tooling_next_steps.md, "Test
selection" bullet 3): one NDJSON object per target with structural
facts, matching the {"field": value, ...}\n style compiler --json
output already uses (compiler/diagnostics.w's diag_emit). Plain --list
above is untouched; this is a separate code path selected by --json. */

int wexec_json_hex_digit(int value):
	if (value < 10):
		return '0' + value
	return 'a' + value - 10


void wexec_json_append_string(string_builder* s, char* text):
	string_append_char(s, '"')
	int i = 0
	while (text[i] != 0):
		int ch = text[i] & 255
		if (ch == '"'):
			string_append(s, c"\\\"")
		else if (ch == 92):
			string_append(s, c"\\\\")
		else if (ch == 10):
			string_append(s, c"\\n")
		else if (ch == 13):
			string_append(s, c"\\r")
		else if (ch == 9):
			string_append(s, c"\\t")
		else if (ch < 32):
			string_append(s, c"\\u00")
			string_append_char(s, wexec_json_hex_digit(ch >> 4))
			string_append_char(s, wexec_json_hex_digit(ch & 15))
		else:
			string_append_char(s, ch)
		i = i + 1
	string_append_char(s, '"')


void wexec_json_append_string_array(string_builder* s, list[char*] values):
	string_append_char(s, '[')
	int i = 0
	while (i < values.length):
		if (i > 0):
			string_append(s, c", ")
		wexec_json_append_string(s, values[i])
		i = i + 1
	string_append_char(s, ']')


void wexec_json_field_string_array(string_builder* s, char* name, list[char*] values):
	wexec_json_append_string(s, name)
	string_append(s, c": ")
	wexec_json_append_string_array(s, values)


void wexec_json_field_int(string_builder* s, char* name, int value):
	wexec_json_append_string(s, name)
	string_append(s, c": ")
	string_append_int(s, value)


void wexec_json_field_bool(string_builder* s, char* name, int value):
	wexec_json_append_string(s, name)
	string_append(s, c": ")
	if (value):
		string_append(s, c"true")
	else:
		string_append(s, c"false")


map[char*, int] wexec_generate_exclude_set
int wexec_generate_exclude_loaded


# "generate.exclude" (build.base.json) lists source paths wbuildgen
# should not auto-generate a target for; it is stripped from the
# generated build.json (tools/wbuildgen.w), so this is only ever
# non-empty when the manifest handed to wexec still carries it (e.g.
# -f build.base.json, or a fixture manifest built to exercise this).
void wexec_load_generate_exclude():
	if (wexec_generate_exclude_loaded):
		return
	wexec_generate_exclude_loaded = 1
	wexec_generate_exclude_set = new map[char*, int]
	json_value* generate = json_object_get(wexec_manifest, c"generate")
	if (generate == 0):
		return
	if (generate.type != json_type_object()):
		return
	json_value* exclude = json_object_get(generate, c"exclude")
	if (exclude == 0):
		return
	if (exclude.type != json_type_array()):
		return
	int i = 0
	while (i < json_array_length(exclude)):
		json_value* entry = json_array_get(exclude, i)
		if (entry.type == json_type_string()):
			wexec_generate_exclude_set[entry.string_value] = 1
		i = i + 1


int wexec_roots_in_generate_exclude(list[char*] roots):
	wexec_load_generate_exclude()
	for char* root in roots:
		if (wexec_generate_exclude_set.get(root, 0)):
			return 1
	return 0


int wexec_step_shells_out(json_value* step):
	json_value* cmd = json_object_get(step, c"cmd")
	if (cmd == 0):
		return 0
	if (cmd.type != json_type_array()):
		return 0
	if (json_array_length(cmd) < 1):
		return 0
	json_value* first = json_array_get(cmd, 0)
	if (first.type != json_type_string()):
		return 0
	if (strcmp(first.string_value, c"sh") == 0):
		return 1
	if (strcmp(first.string_value, c"bash") == 0):
		return 1
	return 0


# True when any step's argv[0] is a shell ("sh"/"bash") running an
# inline "-c" script or a shell script file, rather than a direct
# binary; those steps have no argv-visible relationship to the files
# they actually touch, unlike a plain "bin/wv2 root.w -o out" step.
int wexec_target_shells_out(json_value* target):
	json_value* steps = json_object_get(target, c"steps")
	if (steps == 0):
		return 0
	if (steps.type != json_type_array()):
		return 0
	int i = 0
	while (i < json_array_length(steps)):
		json_value* step = json_array_get(steps, i)
		if (step.type == json_type_object()):
			if (wexec_step_shells_out(step)):
				return 1
		i = i + 1
	return 0


void wexec_list_json_one(wstream* out, char* name):
	json_value* target = wexec_targets.get(name, 0)

	json_value* steps = json_object_get(target, c"steps")
	int step_count = 0
	if (steps != 0):
		if (steps.type == json_type_array()):
			step_count = json_array_length(steps)

	list[char*] deps = new list[char*]
	json_value* deps_value = json_object_get(target, c"deps")
	if (deps_value != 0):
		if (deps_value.type == json_type_array()):
			int i = 0
			while (i < json_array_length(deps_value)):
				json_value* dep = json_array_get(deps_value, i)
				if (dep.type == json_type_string()):
					deps.push(dep.string_value)
				i = i + 1

	list[char*] archs = new list[char*]
	list[char*] roots = new list[char*]
	wexec_deps_collect_roots(target, archs, roots)
	list[char*] compile_roots = new list[char*]
	int r = 0
	while (r < roots.length):
		char* tagged = roots[r]
		if (strcmp(archs[r], c"x86") != 0):
			# Same "<arch> <root>" spelling wexec_deps_entry_key uses for
			# bin/.wexec_deps_cache records, so a reader can cross-reference.
			tagged = wexec_deps_entry_key(archs[r], roots[r])
		compile_roots.push(tagged)
		r = r + 1

	string_builder* line = string_new()
	string_append_char(line, '{')
	wexec_json_append_string(line, c"name")
	string_append(line, c": ")
	wexec_json_append_string(line, name)
	string_append(line, c", ")
	wexec_json_field_int(line, c"step_count", step_count)
	string_append(line, c", ")
	wexec_json_field_string_array(line, c"deps", deps)
	string_append(line, c", ")
	wexec_json_field_string_array(line, c"compile_roots", compile_roots)
	string_append(line, c", ")
	wexec_json_field_bool(line, c"shells_out", wexec_target_shells_out(target))
	string_append(line, c", ")
	wexec_json_field_bool(line, c"generate_exclude", wexec_roots_in_generate_exclude(roots))
	string_append_char(line, '}')
	stream_write_line(out, line.data)
	string_free(line)


void wexec_list_targets_json():
	wstream* out = stdout_writer()
	for char* name in wexec_names:
		wexec_list_json_one(out, name)
	stream_flush(out)


void wexec_report_ok():
	string_builder* s = string_new()
	string_append(s, c"wexec: OK (")
	string_append_int(s, wexec_completed)
	string_append(s, c" targets)")
	wstream* out = stdout_writer()
	stream_write_line(out, s.data)
	stream_flush(out)
	string_free(s)


# Default parallelism: one target per online CPU.
int wexec_default_jobs():
	char* text = file_read_text(c"/proc/cpuinfo")
	if (text == 0):
		return 1
	int count = 0
	int line_start = 1
	int i = 0
	while (text[i] != 0):
		if (line_start):
			if (starts_with(text + i, c"processor")):
				count = count + 1
		line_start = text[i] == 10
		i = i + 1
	free(text)
	if (count < 1):
		return 1
	return count


/* --trace <target> (issue #251 Direction 2, tools/wexec_trace.w): builds
the "declared" input set a traced target's reads are checked against,
mirroring exactly what wexec_cache_key already treats as this target's
cache-relevant inputs -- explicit "inputs" (files, and every file under
a directory prefix) plus, when bin/wv2 exists, the deps-driven
compile-root closures wexec_deps_collect_roots/wexec_deps_lookup compute
for caching. Dependency targets' own inputs are not folded in (a
dependency's cache key is opaque here just as it is in wexec_cache_key);
only this target's own declared inputs and its own steps' compile
roots count. */

# Splits a deps-closure blob (wexec_deps_run's newline-guarded format,
# also walked by wexec_deps_save) into individual file paths, adding
# each to `set`. Cloned since the blob's own storage is reused/rewritten
# elsewhere (bin/.wexec_deps_cache saves), unlike the "inputs" strings
# below, which point straight into the parsed manifest and outlive this
# call already.
void wexec_trace_add_blob_lines(map[char*, int] dest, char* blob):
	if (blob == 0):
		return
	string_builder* line = string_new()
	int j = 0
	while (blob[j] != 0):
		if (blob[j] == 10):
			if (line.length > 0):
				dest[strclone(line.data)] = 1
			string_clear(line)
		else:
			string_append_char(line, blob[j])
		j = j + 1
	string_free(line)


map[char*, int] wexec_trace_collect_declared(json_value* target):
	map[char*, int] declared = new map[char*, int]
	json_value* inputs = json_object_get(target, c"inputs")
	if (inputs != 0):
		if (inputs.type == json_type_array()):
			int i = 0
			while (i < json_array_length(inputs)):
				json_value* entry = json_array_get(inputs, i)
				if (entry.type == json_type_string()):
					char* path = entry.string_value
					int n = strlen(path)
					if ((n > 0) && (path[n - 1] == '/')):
						char* dir = strclone(path)
						dir[n - 1] = 0
						list[char*] walked = new list[char*]
						wexec_collect_dir(dir, walked)
						for char* found in walked:
							declared[found] = 1
						free(dir)
					else:
						declared[path] = 1
				i = i + 1
	if (wexec_deps_usable()):
		list[char*] archs = new list[char*]
		list[char*] roots = new list[char*]
		wexec_deps_collect_roots(target, archs, roots)
		int r = 0
		while (r < roots.length):
			declared[roots[r]] = 1
			wexec_deps_entry* entry = wexec_deps_lookup(archs[r], roots[r])
			if ((entry.failed == 0) && (entry.blob != 0)):
				wexec_trace_add_blob_lines(declared, entry.blob)
			r = r + 1
	return declared


int wexec_trace_cmd(char* name, int hermetic):
	json_value* target = wexec_targets.get(name, 0)
	if (target == 0):
		wexec_error2(c"unknown target ", name)
		return 1
	map[char*, int] declared = wexec_trace_collect_declared(target)
	return wexec_trace_run(name, target, declared, hermetic)


/* Advisory single-writer lock on the managed bin/ directory
(docs/projects/ai_tooling_next_steps.md, "Two ./wbuild/wexec invocations
racing in the same worktree" bullet): a foregrounded './wbuild verify'
and a still-running backgrounded './wbuild test_changed' in the same
worktree both write/execute the same bin/wv2, and the loser's compile
just dies with a bare "could not open output file". main() now takes
this lock right before it runs any target's steps (wexec_execute,
below), so a second overlapping invocation fails fast with a clear
message instead of silently corrupting the first one's output.

Scope is per managed bin/ directory, not global: the lock file lives at
"bin/.wexec_lock", relative to the current working directory -- the same
convention "bin/.wexec_cache/" and "bin/.wexec_deps_cache" already use.
Two unrelated worktrees never collide because each has its own, entirely
separate "bin/".

Reentrancy: wexec's own test targets (wexec_test and friends,
build.base.json) run "bin/wexec -f tests/wexec/*.json <target>" as a
*step* of an outer wexec invocation that already holds this very lock,
against the exact same bin/ -- not a race, since the outer process is
blocked in wait4() on this child for the whole step. wexec_lock_acquire
marks WEXEC_LOCK_HELD=1 in the environment the moment it succeeds
(env_copy_with, swapped into environ_ptr so every subprocess this run
spawns inherits it through execve -- including transitively, through
intermediate non-wexec programs like bin/wtest's own "--run" shelling
out to bin/wexec again); a nested wexec sees the marker
(wexec_lock_is_reentrant) and skips locking entirely, trusting the
already-serialized ancestor. The mutation happens once, in the parent,
before wexec_execute forks any worker (wexec_launch) -- workers inherit
the updated environ_ptr for free via fork()'s copy-on-write memory, no
extra threading needed.

Mechanism: O_CREAT|O_EXCL (193 = O_WRONLY|O_CREAT|O_EXCL, the same
combination libs/extras/vcs/cas.w's cas_store_bytes uses) so at most one
caller ever wins the create; the winner writes its own pid, decimal, no
trailing newline. A loser reads the pid back and checks it is still
alive via kill(pid, 0) -- POSIX's null-signal existence probe, sent to no
one, just an ESRCH/exists check. This is more portable across the arches
wexec.w targets than parsing /proc: arm64_darwin has no procfs at all,
so a /proc/<pid> check would read every live macOS lock as stale. If the
recorded pid is dead, the lock is stale -- left behind by a SIGKILLed
holder (no unwind, no release) or by any of the many direct exit() calls
reachable from this process's own dependency graph (defer does not run
on exit()/panic paths yet, see docs/projects/defer.md's "Possible future
work" -- an in-region exit() leaves the same shape of stale lock a
SIGKILL would, and self-heals the same way) -- so it is reclaimed and the
create retried once. Release is a plain 'defer' registered right after a
successful acquire in main(), so it fires on every return path taken
after that point (grammar/defer.w, docs/projects/defer.md). */

char* wexec_lock_file():
	return c"bin/.wexec_lock"


int wexec_lock_is_reentrant():
	return env_get(c"WEXEC_LOCK_HELD") != 0


void wexec_lock_mark_children():
	environ_ptr = cast(int, env_copy_with(env_current(), c"WEXEC_LOCK_HELD", c"1"))


# 1 when a process with this pid currently exists (see the block comment
# above for why kill(pid, 0) instead of /proc). kill returns -EPERM (-1)
# for a process that exists but this user may not signal (e.g. pid 1
# probed from an unprivileged CI runner) -- existence is all the
# null-signal probe asks, so only ESRCH means the holder is gone.
int wexec_pid_alive(int pid):
	if (pid <= 0):
		return 0
	int r = kill(pid, 0)
	if (r >= 0):
		return 1
	return r == -1


int wexec_lock_read_pid(char* path):
	char* text = file_read_text(path)
	if (text == 0):
		return 0
	int pid = atoi(text)
	free(text)
	return pid


# At most one caller ever sees fd >= 0 here for a given path: O_EXCL
# fails every later attempt while the file exists.
int wexec_lock_try_create(char* path):
	# 193 = O_WRONLY | O_CREAT | O_EXCL, 420 = rw-r--r--
	int fd = open(path, 193, 420)
	if (fd < 0):
		return 0
	char* pid_text = itoa(getpid())
	write(fd, pid_text, strlen(pid_text))
	free(pid_text)
	close(fd)
	return 1


void wexec_lock_conflict(char* path, int pid):
	wstream* err = stderr_writer()
	stream_write_line(err, cstr(f"wexec: another build is running in this directory (pid {pid}); remove {path} if stale"))
	stream_flush(err)


# Acquires the per-bin-directory build lock, or reports why it could not
# and returns 0 (the caller exits nonzero without ever having created the
# lock file). A nested wexec invocation spawned by a step of an outer,
# already-locked wexec (see the block comment above) always returns 1
# without touching the lock file at all.
int wexec_lock_acquire():
	if (wexec_lock_is_reentrant()):
		return 1
	char* path = wexec_lock_file()
	if (wexec_lock_try_create(path)):
		wexec_lock_held = 1
		wexec_lock_mark_children()
		return 1
	int pid = wexec_lock_read_pid(path)
	if (wexec_pid_alive(pid)):
		wexec_lock_conflict(path, pid)
		return 0
	# Stale: a dead pid (SIGKILL, crash, or an exit() bypassing defer --
	# see the block comment above) means nobody is coming back to release
	# this lock. Reclaim it and retry exactly once; a genuine winner of
	# that retry race reports its own, unrelated failure below.
	unlink(path)
	if (wexec_lock_try_create(path)):
		wexec_lock_held = 1
		wexec_lock_mark_children()
		return 1
	wexec_error2(c"cannot acquire build lock: ", path)
	return 0


# Registered via 'defer' immediately after a successful wexec_lock_acquire
# in main(), so it runs on every return path taken after that point. A
# no-op when this process never actually created the lock (a reentrant
# nested run, or main() returning before the lock was ever attempted).
void wexec_lock_release():
	if (wexec_lock_held == 0):
		return
	wexec_lock_held = 0
	unlink(wexec_lock_file())


int main(int argc, int argv):
	wexec_jobs = 0
	char* manifest_path = c"build.json"
	list[char*] requested = new list[char*]
	int list_only = 0
	int list_json = 0
	char* explain_cache_target = 0
	char* trace_target = 0
	int hermetic = 0
	int i = 1
	while (i < argc):
		char** arg = argv + i * __word_size__
		if (strcmp(*arg, c"-f") == 0):
			i = i + 1
			if (i >= argc):
				wexec_usage()
				return 1
			char** value = argv + i * __word_size__
			manifest_path = *value
		else if (strcmp(*arg, c"--list") == 0):
			list_only = 1
		else if (strcmp(*arg, c"--json") == 0):
			list_json = 1
		else if (strcmp(*arg, c"--explain-cache") == 0):
			i = i + 1
			if (i >= argc):
				wexec_usage()
				return 1
			char** target_value = argv + i * __word_size__
			explain_cache_target = *target_value
		else if (strcmp(*arg, c"--trace") == 0):
			i = i + 1
			if (i >= argc):
				wexec_usage()
				return 1
			char** trace_value = argv + i * __word_size__
			trace_target = *trace_value
		else if (strcmp(*arg, c"--hermetic") == 0):
			hermetic = 1
		else if (strcmp(*arg, c"--no-cache") == 0):
			wexec_no_cache = 1
		else if (strcmp(*arg, c"--keep-going") == 0):
			wexec_keep_going = 1
		else if (strcmp(*arg, c"--ordered-output") == 0):
			wexec_ordered_output = 1
		else if (strcmp(*arg, c"-j") == 0):
			i = i + 1
			if (i >= argc):
				wexec_usage()
				return 1
			char** jobs_value = argv + i * __word_size__
			wexec_jobs = atoi(*jobs_value)
		else if (starts_with(*arg, c"-j")):
			char* digits = *arg
			wexec_jobs = atoi(digits + 2)
		else:
			requested.push(*arg)
		i = i + 1
	if (wexec_jobs < 1):
		wexec_jobs = wexec_default_jobs()

	if (wexec_load_manifest(manifest_path)):
		return 1
	if (explain_cache_target != 0):
		return wexec_explain_cache(explain_cache_target)
	if (trace_target != 0):
		return wexec_trace_cmd(trace_target, hermetic)
	if (list_only):
		if (list_json):
			wexec_list_targets_json()
		else:
			wexec_list_targets()
		return 0

	# Direct-file UX (issue #323 stage 1): "[selector] <file>.w" in place
	# of a target name list. Recognized only in exactly these two shapes,
	# so every other invocation (including a literal target that happens
	# to be named like a selector) is untouched.
	char* direct_arch = 0
	char* direct_path = 0
	if ((requested.length == 1) && ends_with(requested[0], c".w")):
		direct_arch = c"x86"
		direct_path = requested[0]
	else if ((requested.length == 2) && wexec_selector_word(requested[0]) && ends_with(requested[1], c".w")):
		direct_arch = requested[0]
		direct_path = requested[1]
	if (direct_path != 0):
		char* resolved = wexec_resolve_direct_file(direct_arch, direct_path)
		if (resolved == 0):
			return 1
		requested = new list[char*]
		requested.push(resolved)

	if (requested.length == 0):
		wexec_usage()
		wexec_list_targets()
		return 1

	# From here on we actually run target steps that can write into bin/
	# (compiles, links, caches) -- take the single-writer lock on this
	# invocation's managed bin/ directory first. See the block comment
	# above wexec_lock_file for the full design (per-bin-dir scope,
	# reentrant skip for wexec's own nested test-harness invocations).
	if (wexec_lock_acquire() == 0):
		return 1
	defer wexec_lock_release()

	int failed = wexec_execute(requested)
	# Cache keys (and any recomputed import closures) are computed in
	# the parent only, so the closure cache is saved here once, after
	# the run — on failure too, so a red run still keeps its deps work.
	wexec_deps_save()
	if (failed):
		return 1
	wexec_report_ok()
	return 0
