# wbuild: binary=wbuildd staged
/*
wbuildd: the persistent build/check daemon (issue #231,
docs/projects/wbuildd.md -- stage 2: the read-only milestone plus the
build RPC and auto-start of issue #483).

One binary is both the daemon and its thin client:

  bin/wbuildd [--socket P] [--no-daemon | --require-daemon] <command> ...

  serve    run the daemon in the foreground (Ctrl-C / 'stop' ends it)
  start    spawn 'serve' detached, wait until it answers, print its pid
  stop     ask a running daemon to shut down (no-op when none runs)
  status   print the running daemon's counters ('--json' for the raw
           RPC result); exits 1 when no daemon answers

  check    ...  == bin/wv2 check ...      (e.g. check --json file.w)
  deps     ...  == bin/wv2 deps ...
  symbols  ...  == bin/wv2 symbols ...
  changed  ...  == bin/wtest changed ...  (stdin path list included)
  build    ...  == bin/wexec ...          (targets, --keep-going, -j, -f)

The query commands print exactly the one-shot command's stdout,
stderr and exit status. They try the daemon first and fall back to
exec'ing the one-shot command whenever no daemon answers (no socket,
connection refused, a malformed or error response, a different working
directory) -- the §2.6 invariant: deleting the socket and killing the
daemon is equivalent to it never having existed. WBUILDD=0 (or
--no-daemon) skips the daemon outright; --require-daemon turns a
fallback into an error (exit 2), which is how tests/wbuildd_test.w
proves a response really came from the daemon.

Auto-start (§2.2): when no daemon answers, a client command first
spawns one ('serve --detach', logging to bin/.wbuildd.log, or to
<socket>.log for a --socket other than the default) and retries the
connection before it falls back; nothing extra is printed, so the
output is still exactly the one-shot command's. An auto-started daemon
exits after WBUILDD_IDLE_TIMEOUT_MS (default one hour) without a
request, and runs no test_changed prewarm when WBUILDD_PREWARM=0.
Only a working directory holding build.base.json (a checkout root)
auto-starts one; --no-autostart or WBUILDD_AUTOSTART=0 turns it off.

The build command (the build RPC) does not re-run bin/wexec: the
executor is compiled into this binary (tools/wexec.w), and the daemon
forks a child that runs it in-process with the client's own stdin,
stdout and stderr (passed over the socket with SCM_RIGHTS,
lib/unix_fds.w), environment, umask and arguments. Output therefore
streams live, byte for byte what 'bin/wexec ARGS' prints, and the exit
status is the child's. The child starts from the daemon's warm state:
the generated default manifest, already parsed, and the content hashes
of every file an earlier build hashed (wexec_file_hash, which backs the
import-closure checks of the deps-driven cache keys). Cache keys, stamps
and bin/.wexec_deps_cache are wexec's own, unchanged, so a daemon build
and a one-shot build agree on every hit. The client forwards SIGINT/
SIGTERM/SIGHUP to the build child, whose wexec termination handler
tears the build down as it would in a one-shot run.

Daemon side. A single-threaded lib/event_loop.w loop multiplexes
  - the unix-socket listener (lib/net.w socket_listen_unix_path),
    speaking JSON-RPC 2.0 over lib/framing.w Content-Length frames via
    lib/json_rpc.w (methods: check, deps, symbols, test_changed,
    status, shutdown);
  - one lib/inotify.w fd watching every directory of the tree (dot
    directories such as .git skipped; inotify is not recursive, so the
    walk adds one watch per directory and new directories are added as
    they appear);
  - timers for the test_changed prewarm below;
  - one report pipe per build in flight: the child writes the state it
    learned (new content hashes, a freshly generated manifest) there
    before it exits, and the daemon answers the client once it reads
    EOF and reaps the child.

Warm state, and how each piece is invalidated:

  check / deps / symbols: every answer (stdout, stderr, status) is
  memoized under its exact argument list together with the import
  closure of its root file -- 'bin/wv2 deps [arch] <root>', itself a
  memoized entry. A later request with the same arguments is answered
  from memory with no compiler run until inotify reports a change to a
  file in that closure. Anything that can change import RESOLUTION
  rather than content (a .w file created, deleted or renamed, a
  directory created/moved, a C header (.h/.c) edited, bin/wv2 itself
  rebuilt, an inotify queue overflow) drops the whole memo. Requests
  whose closure cannot be pinned down (more than one root, an absolute
  or '..' path, a root whose deps run fails) are simply never cached,
  so they always run the compiler: correct, just not warm.

  test_changed: runs 'bin/wtest changed ...' per request, whose own
  bin/.wtest_deps_cache holds the import closures of every manifest
  root. The daemon keeps THAT cache warm: at startup and again
  (debounced) after any .w edit or compiler rebuild it runs
  'bin/wtest cache -f <manifest>' in the background, so the ~143s cold
  closure walk (wbuildd.md §1.2) is paid off the agent's critical
  path. A test_changed request that arrives while a prewarm runs waits
  for it (the cache file has one writer at a time). '--run' (which
  executes builds) is never served; the client runs it one-shot.

  build: the warm content hashes are dropped per path by inotify
  events (any path, bin/ included -- build outputs are inputs of later
  targets) and re-checked against each file's size, inode, mtime and
  ctime before every build, so a write inotify cannot see (an mmap
  write) still rehashes. A hash the child reports is kept only if no
  event touched that path after the fork. The warm manifest is dropped
  by any event outside bin/ (manifest generation reads sources,
  directives, sidecars and build.base.json there, never bin/).

Staleness (§2.2): compiler rebuilds are seen by inotify (bin/wv2,
bin/wtest) and clear the memo; when the daemon's own binary in bin/
(or bin/wexec, whose executor the build RPC must match) is replaced,
the daemon stops listening, finishes the builds in flight and exits,
and the next client auto-starts a fresh one. Requests carry a protocol
number the daemon must match.

Scope (docs/projects/wbuildd.md "Decisions"): Linux x86/x64 only;
darwin/win64/wasm keep the one-shot path. No REPL server in this
process.
*/
import lib.lib
import lib.net
import lib.json_rpc
import lib.event_loop
import lib.inotify
import lib.process
import lib.file
import lib.env
import lib.stat
import lib.time
import lib.unix_fds
import structures.string
import structures.json
import tools.wexec


int wbd_protocol():
	return 2


/* ---- small helpers ---- */

void wbd_err(char* text):
	write(2, text, strlen(text))


void wbd_err2(char* a, char* b):
	wbd_err(a)
	wbd_err(b)
	wbd_err(c"\n")


void wbd_out(char* text):
	write(1, text, strlen(text))


char* wbd_arg(int argv, int i):
	char** slot = cast(char**, argv + i * __word_size__)
	return *slot


int wbd_prefix_eq(char* a, char* b, int n):
	int i = 0
	while (i < n):
		if (a[i] != b[i]):
			return 0
		if (a[i] == 0):
			return 0
		i = i + 1
	return 1


int wbd_contains(char* text, char* needle):
	int n = strlen(needle)
	int i = 0
	while (text[i] != 0):
		if (wbd_prefix_eq(text + i, needle, n)):
			return 1
		i = i + 1
	return 0


# "./x/./y" style prefixes are stripped so closure entries and event
# paths compare as the plain repo-relative spelling bin/wv2 deps prints.
char* wbd_strip_dot(char* path):
	while ((path[0] == '.') && (path[1] == '/')):
		path = path + 2
	return path


char* wbd_join(char* dir, char* name):
	if (dir[0] == 0):
		return strclone(name)
	string_builder* s = string_new()
	string_append(s, dir)
	string_append_char(s, '/')
	string_append(s, name)
	char* joined = s.data
	free(s)
	return joined


char* wbd_cwd():
	char* buf = malloc(4096)
	int n = getcwd(buf, 4096)
	if (n < 0):
		buf[0] = 0
	return buf


int wbd_is_arch_word(char* word):
	if (strcmp(word, c"x64") == 0):
		return 1
	if (strcmp(word, c"arm64") == 0):
		return 1
	if (strcmp(word, c"arm64_darwin") == 0):
		return 1
	if (strcmp(word, c"win64") == 0):
		return 1
	if (strcmp(word, c"wasm") == 0):
		return 1
	return 0


# sub = 0: no subcommand word (bin/wexec takes its arguments directly).
char** wbd_argv_from(char* tool, char* sub, list[char*] args):
	int first = 2
	if (sub == 0):
		first = 1
	char** argv = strv_new(args.length + first)
	strv_set(argv, 0, tool)
	if (sub != 0):
		strv_set(argv, 1, sub)
	int i = 0
	while (i < args.length):
		strv_set(argv, i + first, args[i])
		i = i + 1
	return argv


/* ---- daemon state ---- */

struct wbd_entry:
	char* key
	char* stdout_text
	char* stderr_text
	int status
	list[char*] closure


char* wbd_socket_path
char* wbd_root
char* wbd_self_name          # basename of our binary when it lives in bin/, else 0
int wbd_inotify_fd
map[int, char*] wbd_watch_dirs
int wbd_watch_count
int wbd_rewatch_pending
list[wbd_entry*] wbd_cache
int wbd_hits
int wbd_misses
int wbd_invalidations
int wbd_requests
int wbd_started_ms
int wbd_stale
event_loop* wbd_loop
jsonrpc_server* wbd_server
int wbd_prewarm_enabled
char* wbd_prewarm_manifest   # 0 = bin/wtest's default manifest
process* wbd_prewarm_proc
int wbd_prewarm_timer        # pending debounce timer id, 0 = none
int wbd_prewarm_poll_timer
int wbd_prewarm_runs
int wbd_idle_timeout_ms       # 0 = serve until stopped
int wbd_last_activity_ms
int wbd_listen_fd
int wbd_stopping              # listener closed; exit once no build is in flight


/* ---- build RPC state ---- */

# One accepted client. Descriptors that arrived with its bytes
# (SCM_RIGHTS) collect in fds until a build request takes them.
struct wbd_conn:
	int fd
	frame_reader* reader
	list[int] fds
	int open
	int watching
	int building


struct wbd_build:
	wbd_conn* conn
	json_value* id
	int pid
	int report_fd
	string_builder* report
	int fork_seq


list[wbd_conn*] wbd_conns
int wbd_builds_active
int wbd_builds_done
int wbd_hashes_merged

# Invalidation sequence numbers: every inotify event that drops warm
# build state bumps wbd_seq, so a build child's report (computed after
# its fork) can tell which of its answers were overtaken by an edit.
int wbd_seq
int wbd_clear_seq                  # last event that dropped every hash
int wbd_manifest_seq               # last event that dropped the manifest
map[char*, int] wbd_touched        # path -> seq of its last event (while builds run)
list[char*] wbd_touched_dirs       # directories whose whole subtree was dropped (while builds run)
list[int] wbd_touched_dir_seqs     # ... and the seq of each drop
map[char*, char*] wbd_hash_sig     # path -> stat signature its warm hash was taken under
char* wbd_manifest_stderr          # what generating the warm manifest printed


int wbd_watch_mask():
	return IN_MODIFY() | IN_CLOSE_WRITE() | IN_MOVED_FROM() | IN_MOVED_TO() | IN_CREATE() | IN_DELETE() | IN_DELETE_SELF() | IN_MOVE_SELF()


int wbd_load_uint16(char* p):
	return (p[0] & 255) + ((p[1] & 255) << 8)


# Adds a watch for rel ("" = the root) and, recursively, every
# non-dot subdirectory under it (the same getdents record walk
# tools/wbuildgen.w uses).
void wbd_watch_tree(char* rel):
	char* path = rel
	if (rel[0] == 0):
		path = c"."
	int wd = inotify_add_watch(wbd_inotify_fd, path, wbd_watch_mask() | IN_ONLYDIR())
	if (wd < 0):
		return
	if ((wd in wbd_watch_dirs) == 0):
		wbd_watch_count = wbd_watch_count + 1
	wbd_watch_dirs[wd] = strclone(rel)
	# 65536 = O_DIRECTORY
	int fd = open(path, 65536, 0)
	if (fd < 0):
		return
	int buffer_size = 32768
	char* buffer = malloc(buffer_size)
	list[char*] children = new list[char*]
	int n = getdents(fd, buffer, buffer_size)
	while (n > 0):
		int off = 0
		while (off < n):
			char* entry = buffer + off
			int reclen = wbd_load_uint16(entry + 2 * __word_size__)
			char* entry_name = entry + 2 * __word_size__ + 2
			int kind = entry[reclen - 1] & 255
			if ((kind == 4) && (entry_name[0] != '.')):
				children.push(wbd_join(rel, entry_name))
			off = off + reclen
		n = getdents(fd, buffer, buffer_size)
	free(buffer)
	close(fd)
	for char* child in children:
		wbd_watch_tree(child)


void wbd_on_inotify(int fd, int revents, void* ctx);
void wbd_begin_stop();


/* ---- warm build state (see the header comment's "build:" notes) ---- */

# A statx-based identity of a file's current content: size, inode,
# mtime and ctime (seconds and nanoseconds), or "-" when it is missing.
char* wbd_file_sig(char* path):
	char* buf = malloc(FILE_STATX_BUF_SIZE())
	int err = statx(path, 0, FILE_STATX_BASIC_STATS(), buf)
	if (err != 0):
		free(buf)
		return strclone(c"-")
	string_builder* s = string_new()
	string_append_int(s, load_word(buf + FILE_STATX_SIZE_OFFSET()))
	string_append_char(s, ':')
	string_append_int(s, load_word(buf + FILE_STATX_INO_OFFSET()))
	string_append_char(s, ':')
	string_append_int(s, load_word(buf + FILE_STATX_MTIME_OFFSET()))
	string_append_char(s, '.')
	string_append_int(s, load_int32(buf + FILE_STATX_MTIME_OFFSET() + 8))
	string_append_char(s, ':')
	string_append_int(s, load_word(buf + FILE_STATX_CTIME_OFFSET()))
	string_append_char(s, '.')
	string_append_int(s, load_int32(buf + FILE_STATX_CTIME_OFFSET() + 8))
	free(buf)
	char* sig = s.data
	free(s)
	return sig


# Only plain repo-relative paths inside the watched tree are kept warm:
# nothing absolute, nothing reaching out with '..', nothing under an
# unwatched dot directory, and one spelling per file ('./x' is not).
int wbd_hash_path_ok(char* path):
	if ((path[0] == 0) || (path[0] == '/') || (path[0] == '.')):
		return 0
	if (wbd_contains(path, c"..") || wbd_contains(path, c"/.") || wbd_contains(path, c"//")):
		return 0
	return 1


void wbd_hashes_clear():
	wbd_seq = wbd_seq + 1
	wbd_clear_seq = wbd_seq
	wexec_file_hashes = new map[char*, char*]
	wbd_hash_sig = new map[char*, char*]


void wbd_hash_forget(char* path):
	wbd_seq = wbd_seq + 1
	wexec_file_hashes.remove(path)
	wbd_hash_sig.remove(path)
	if (wbd_builds_active > 0):
		wbd_touched[strclone(path)] = wbd_seq


# A directory appeared, vanished or moved: every warm hash under it goes.
void wbd_hashes_forget_under(char* dir):
	wbd_seq = wbd_seq + 1
	char* prefix = strjoin(dir, c"/")
	if (dir[0] == 0):
		prefix = strclone(c"")
	list[char*] paths = wexec_file_hashes.keys()
	for char* path in paths:
		if (starts_with(path, prefix)):
			wexec_file_hashes.remove(path)
			wbd_hash_sig.remove(path)
	if (wbd_builds_active > 0):
		wbd_touched_dirs.push(prefix)
		wbd_touched_dir_seqs.push(wbd_seq)
	else:
		free(prefix)


# Did an event since seq drop path (itself, or a directory above it)?
int wbd_touched_since(char* path, int seq):
	if (wbd_touched.get(path, 0) > seq):
		return 1
	int i = 0
	while (i < wbd_touched_dirs.length):
		if ((wbd_touched_dir_seqs[i] > seq) && starts_with(path, wbd_touched_dirs[i])):
			return 1
		i = i + 1
	return 0


void wbd_manifest_drop():
	wbd_seq = wbd_seq + 1
	wbd_manifest_seq = wbd_seq
	if (wexec_warm_manifest != 0):
		json_free(wexec_warm_manifest)
		wexec_warm_manifest = 0


# Before a build forks: re-stat every warm hash and drop the ones whose
# file changed without an inotify event reaching us.
void wbd_hashes_revalidate():
	list[char*] paths = wexec_file_hashes.keys()
	for char* path in paths:
		char* sig = wbd_file_sig(path)
		char* known = wbd_hash_sig.get(path, 0)
		if ((known == 0) || (strcmp(known, sig) != 0)):
			wexec_file_hashes.remove(path)
			wbd_hash_sig.remove(path)
		free(sig)


# Throws every watch away and walks the tree again: the recovery for a
# moved directory (its old watch descriptors would keep reporting the
# old path) and for an inotify queue overflow.
void wbd_rewatch():
	if (wbd_inotify_fd >= 0):
		event_loop_remove_fd(wbd_loop, wbd_inotify_fd)
		close(wbd_inotify_fd)
	wbd_inotify_fd = inotify_init_nonblocking()
	wbd_watch_dirs = new map[int, char*]
	wbd_watch_count = 0
	wbd_rewatch_pending = 0
	if (wbd_inotify_fd < 0):
		return
	wbd_watch_tree(c"")
	event_loop_add_fd(wbd_loop, wbd_inotify_fd, poll_in(), wbd_on_inotify, 0)


void wbd_entry_free(wbd_entry* e):
	free(e.key)
	free(e.stdout_text)
	free(e.stderr_text)
	for char* p in e.closure:
		free(p)
	free(cast(char*, e))


void wbd_clear_all():
	if (wbd_cache.length > 0):
		wbd_invalidations = wbd_invalidations + wbd_cache.length
	for wbd_entry* e in wbd_cache:
		wbd_entry_free(e)
	wbd_cache = new list[wbd_entry*]


int wbd_closure_has(wbd_entry* e, char* path):
	for char* p in e.closure:
		if (strcmp(p, path) == 0):
			return 1
	return 0


# Drops every memoized answer whose closure contains path.
void wbd_invalidate_path(char* path):
	list[wbd_entry*] kept = new list[wbd_entry*]
	for wbd_entry* e in wbd_cache:
		if (wbd_closure_has(e, path)):
			wbd_invalidations = wbd_invalidations + 1
			wbd_entry_free(e)
		else:
			kept.push(e)
	wbd_cache = kept


wbd_entry* wbd_lookup(char* key):
	for wbd_entry* e in wbd_cache:
		if (strcmp(e.key, key) == 0):
			return e
	return 0


/* ---- test_changed prewarm (bin/wtest cache -f <manifest>) ---- */

int wbd_prewarm_running():
	if (wbd_prewarm_proc == 0):
		return 0
	int status = process_try_wait(wbd_prewarm_proc)
	if (status == process_status_running()):
		return 1
	process_free(wbd_prewarm_proc)
	wbd_prewarm_proc = 0
	wbd_prewarm_runs = wbd_prewarm_runs + 1
	return 0


void wbd_prewarm_wait():
	if (wbd_prewarm_proc == 0):
		return
	process_wait(wbd_prewarm_proc)
	process_free(wbd_prewarm_proc)
	wbd_prewarm_proc = 0
	wbd_prewarm_runs = wbd_prewarm_runs + 1


void wbd_prewarm_poll(int id, void* ctx):
	wbd_prewarm_poll_timer = 0
	if (wbd_prewarm_running()):
		wbd_prewarm_poll_timer = event_loop_add_timer(wbd_loop, 250, wbd_prewarm_poll, 0)


void wbd_prewarm_fire(int id, void* ctx):
	wbd_prewarm_timer = 0
	if (wbd_prewarm_running()):
		# One writer of bin/.wtest_deps_cache at a time: try again once
		# the current pass is done.
		wbd_prewarm_timer = event_loop_add_timer(wbd_loop, 500, wbd_prewarm_fire, 0)
		return
	char** argv = strv_new(4)
	strv_set(argv, 0, c"bin/wtest")
	strv_set(argv, 1, c"cache")
	if (wbd_prewarm_manifest != 0):
		strv_set(argv, 2, c"-f")
		strv_set(argv, 3, wbd_prewarm_manifest)
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_null()
	opts.stdout_mode = process_null()
	opts.stderr_mode = process_null()
	wbd_prewarm_proc = process_spawn(c"bin/wtest", argv, opts)
	free(cast(char*, opts))
	free(cast(char*, argv))
	if ((wbd_prewarm_proc != 0) && (wbd_prewarm_poll_timer == 0)):
		wbd_prewarm_poll_timer = event_loop_add_timer(wbd_loop, 250, wbd_prewarm_poll, 0)


# Debounced: an editor save is often several events, a branch switch
# hundreds; one prewarm runs after the burst settles.
void wbd_prewarm_schedule(int delay_ms):
	if (wbd_prewarm_enabled == 0):
		return
	if (wbd_prewarm_timer != 0):
		event_loop_cancel_timer(wbd_loop, wbd_prewarm_timer)
	wbd_prewarm_timer = event_loop_add_timer(wbd_loop, delay_ms, wbd_prewarm_fire, 0)


char* wbd_prewarm_state():
	if (wbd_prewarm_enabled == 0):
		return c"disabled"
	if (wbd_prewarm_running()):
		return c"running"
	if (wbd_prewarm_timer != 0):
		return c"pending"
	return c"idle"


/* ---- inotify event handling ---- */

int wbd_in_bin(char* dir):
	if (strcmp(dir, c"bin") == 0):
		return 1
	return starts_with(dir, c"bin/")


void wbd_handle_event(inotify_event* ev):
	if (ev.mask & IN_Q_OVERFLOW()):
		wbd_rewatch_pending = 1
		wbd_clear_all()
		wbd_hashes_clear()
		wbd_manifest_drop()
		wbd_prewarm_schedule(1500)
		return
	char* dir = wbd_watch_dirs.get(ev.wd, 0)
	if (dir == 0):
		return
	if (ev.name_length == 0):
		# The watched directory itself went away or moved.
		if (ev.mask & (IN_DELETE_SELF() | IN_MOVE_SELF())):
			if (ev.mask & IN_MOVE_SELF()):
				wbd_rewatch_pending = 1
			wbd_clear_all()
			wbd_hashes_forget_under(dir)
			if (wbd_in_bin(dir) == 0):
				wbd_manifest_drop()
		return
	int changing = IN_CREATE() | IN_DELETE() | IN_MOVED_FROM() | IN_MOVED_TO()
	if (ev.mask & IN_ISDIR()):
		if (ev.name[0] == '.'):
			return
		char* sub = wbd_join(dir, ev.name)
		if (ev.mask & changing):
			# Any path under it may have appeared or vanished (a file
			# created in a new directory before its watch exists sends
			# no event of its own).
			wbd_hashes_forget_under(sub)
			if (wbd_in_bin(dir) == 0):
				wbd_manifest_drop()
		if (ev.mask & IN_CREATE()):
			wbd_watch_tree(sub)
		if (ev.mask & (IN_MOVED_FROM() | IN_MOVED_TO())):
			wbd_rewatch_pending = 1
		free(sub)
		if (ev.mask & changing):
			wbd_clear_all()
			if (wbd_in_bin(dir) == 0):
				wbd_prewarm_schedule(1500)
		return
	int bin = wbd_in_bin(dir)
	char* event_path = wbd_join(dir, ev.name)
	wbd_hash_forget(event_path)
	free(event_path)
	if (bin == 0):
		wbd_manifest_drop()
	if (ends_with(ev.name, c".w")):
		char* path = wbd_join(dir, ev.name)
		if (ev.mask & changing):
			# A new, removed or renamed module can change what an
			# import resolves to anywhere, not just in closures that
			# already named this path.
			wbd_clear_all()
		else:
			wbd_invalidate_path(path)
		free(path)
		# Sources under bin/ are scratch files of tests and tools,
		# never manifest roots worth re-warming bin/wtest for.
		if (bin == 0):
			wbd_prewarm_schedule(1500)
		return
	if (bin):
		if (strcmp(dir, c"bin") == 0):
			if ((strcmp(ev.name, c"wv2") == 0) || (strcmp(ev.name, c"wtest") == 0)):
				wbd_clear_all()
				wbd_prewarm_schedule(1500)
			if (wbd_self_name != 0):
				if (strcmp(ev.name, wbd_self_name) == 0):
					if (ev.mask & (IN_MOVED_TO() | IN_CREATE() | IN_CLOSE_WRITE())):
						wbd_stale = 1
			# The build RPC runs the executor compiled into this binary;
			# a rebuilt bin/wexec means the one-shot command it stands in
			# for may have moved on.
			if (strcmp(ev.name, c"wexec") == 0):
				if (ev.mask & (IN_MOVED_TO() | IN_CREATE() | IN_CLOSE_WRITE())):
					wbd_stale = 1
		return
	# C-import headers are the compiler's only non-.w inputs.
	if (ends_with(ev.name, c".h") || ends_with(ev.name, c".c")):
		wbd_clear_all()
	if (strcmp(ev.name, c"build.base.json") == 0):
		wbd_prewarm_schedule(1500)


# Reads and applies every queued event without blocking. Called from
# the loop when the fd is readable AND at the top of every request, so
# an edit that finished before the request was sent is always seen
# before the answer is chosen.
void wbd_drain_events():
	if (wbd_inotify_fd < 0):
		return
	char* buf = malloc(INOTIFY_BUF_SIZE())
	inotify_event ev
	int n = read(wbd_inotify_fd, buf, INOTIFY_BUF_SIZE())
	while (n > 0):
		int off = 0
		while ((off >= 0) && (off < n)):
			off = inotify_event_parse(buf, n, off, &ev)
			if (off >= 0):
				wbd_handle_event(&ev)
		n = read(wbd_inotify_fd, buf, INOTIFY_BUF_SIZE())
	free(buf)
	if (wbd_rewatch_pending):
		wbd_rewatch()
	if (wbd_stale && (wbd_stopping == 0)):
		wbd_err(c"wbuildd: own binary (or bin/wexec) replaced; exiting once in-flight builds finish\n")
		wbd_begin_stop()


void wbd_on_inotify(int fd, int revents, void* ctx):
	wbd_drain_events()


/* ---- request handling ---- */

void wbd_touch():
	wbd_last_activity_ms = time_monotonic_ms()


# --idle-timeout-ms: a daemon nobody has asked anything for that long
# (and with no prewarm in flight) exits on its own -- the safety net a
# test uses so a failed run cannot leave a daemon behind.
void wbd_idle_check(int id, void* ctx):
	if (wbd_prewarm_running() || (wbd_builds_active > 0) || wbd_stopping):
		return
	if (time_monotonic_ms() - wbd_last_activity_ms > wbd_idle_timeout_ms):
		wbd_err(c"wbuildd: idle timeout; exiting\n")
		wbd_begin_stop()


json_value* wbd_error_result(char* message):
	json_value* result = json_object()
	json_object_set(result, c"error", json_string(message))
	return result


json_value* wbd_output_result(char* out, char* err, int status, int cached):
	json_value* result = json_object()
	json_object_set(result, c"stdout", json_string(out))
	json_object_set(result, c"stderr", json_string(err))
	json_object_set(result, c"status", json_int(status))
	json_object_set(result, c"cached", json_bool(cached))
	return result


# Validates the common request envelope and returns its argument list,
# or 0 with *why set.
list[char*] wbd_request_args(json_value* params, char** why):
	if ((params == 0) || (params.type != json_type_object())):
		*why = c"params must be an object"
		return 0
	json_value* protocol = json_object_get(params, c"protocol")
	if ((protocol == 0) || (protocol.type != json_type_int()) || (protocol.int_value != wbd_protocol())):
		*why = c"protocol mismatch"
		return 0
	json_value* cwd = json_object_get(params, c"cwd")
	if ((cwd == 0) || (cwd.type != json_type_string()) || (strcmp(cwd.string_value, wbd_root) != 0)):
		*why = c"client working directory differs from the daemon's root"
		return 0
	json_value* args = json_object_get(params, c"args")
	if ((args == 0) || (args.type != json_type_array())):
		*why = c"args must be an array"
		return 0
	list[char*] out = new list[char*]
	int i = 0
	while (i < json_array_length(args)):
		json_value* a = json_array_get(args, i)
		if (a.type != json_type_string()):
			*why = c"args must be strings"
			return 0
		out.push(a.string_value)
		i = i + 1
	return out


char* wbd_key(char* sub, list[char*] args):
	string_builder* s = string_new()
	string_append(s, sub)
	for char* a in args:
		string_append_char(s, 10)
		string_append(s, a)
	char* key = s.data
	free(s)
	return key


# Parses 'bin/wv2 deps' stdout into a normalized closure list, or 0
# when any entry could escape the watched tree.
list[char*] wbd_parse_closure(char* text):
	list[char*] closure = new list[char*]
	string_builder* line = string_new()
	int i = 0
	int ok = 1
	while (ok):
		int c = text[i]
		if ((c == 10) || (c == 0)):
			if (line.length > 0):
				char* p = wbd_strip_dot(line.data)
				if ((p[0] == '/') || wbd_contains(p, c"..")):
					ok = 0
				else:
					closure.push(strclone(p))
			string_clear(line)
			if (c == 0):
				break
		else:
			string_append_char(line, c)
		i = i + 1
	string_free(line)
	if ((ok == 0) || (closure.length == 0)):
		return 0
	return closure


list[char*] wbd_clone_list(list[char*] items):
	list[char*] copy = new list[char*]
	for char* p in items:
		copy.push(strclone(p))
	return copy


int wbd_cache_limit():
	return 256


# Bounded memo: past the limit the oldest answer goes (it is only
# recomputed if asked for again).
void wbd_evict_oldest():
	list[wbd_entry*] kept = new list[wbd_entry*]
	int i = 1
	while (i < wbd_cache.length):
		kept.push(wbd_cache[i])
		i = i + 1
	wbd_entry_free(wbd_cache[0])
	wbd_cache = kept


void wbd_store(char* key, process_result* result, list[char*] closure):
	if (wbd_cache.length >= wbd_cache_limit()):
		wbd_evict_oldest()
	wbd_entry* e = new wbd_entry()
	e.key = key
	e.stdout_text = strclone(result.stdout_text)
	e.stderr_text = strclone(result.stderr_text)
	e.status = result.status
	e.closure = closure
	wbd_cache.push(e)


process_result* wbd_run_tool(char* tool, char* sub, list[char*] args, char* stdin_text, int timeout_ms):
	char** argv = wbd_argv_from(tool, sub, args)
	process_result* result = process_run(tool, argv, 0, stdin_text, timeout_ms)
	free(cast(char*, argv))
	return result


int wbd_closure_has_path(list[char*] closure, char* path):
	for char* p in closure:
		if (strcmp(p, path) == 0):
			return 1
	return 0


# The import closure pinning a request's answer: the memoized (or
# freshly run) 'bin/wv2 deps [arch] <root>' for its single root file.
# Returns an owned list, or 0 when the request cannot be cached. When
# the request IS that plain deps query, its own (request_key,
# request_result) answer is reused instead of running deps twice.
list[char*] wbd_closure_for(list[char*] args, char* request_key, process_result* request_result):
	char* arch = 0
	char* root = 0
	int roots = 0
	for char* a in args:
		if (wbd_is_arch_word(a)):
			arch = a
		else if ((a[0] != '-') && ends_with(a, c".w")):
			root = a
			roots = roots + 1
	if (roots != 1):
		return 0
	if ((root[0] == '/') || wbd_contains(root, c"..")):
		return 0
	list[char*] deps_args = new list[char*]
	if (arch != 0):
		deps_args.push(arch)
	deps_args.push(root)
	char* key = wbd_key(c"deps", deps_args)
	wbd_entry* e = wbd_lookup(key)
	if (e != 0):
		free(key)
		return wbd_clone_list(e.closure)
	process_result* result = 0
	int owned = 1
	if (strcmp(key, request_key) == 0):
		result = request_result
		owned = 0
	else:
		result = wbd_run_tool(c"bin/wv2", c"deps", deps_args, 0, 600000)
	if (result == 0):
		free(key)
		return 0
	list[char*] closure = 0
	if (result.status == 0):
		closure = wbd_parse_closure(result.stdout_text)
	# The root itself must be in its own closure, or a path spelling
	# mismatch would make edits to it invisible.
	if (closure != 0):
		if (wbd_closure_has_path(closure, wbd_strip_dot(root)) == 0):
			closure = 0
	if (closure == 0):
		if (owned):
			process_result_free(result)
		free(key)
		return 0
	wbd_store(key, result, closure)
	if (owned):
		process_result_free(result)
	return wbd_clone_list(closure)


# check / deps / symbols: memoized 'bin/wv2 <sub> <args...>'.
json_value* wbd_serve_wv2(char* sub, json_value* params):
	wbd_requests = wbd_requests + 1
	wbd_touch()
	wbd_drain_events()
	char* why = 0
	list[char*] args = wbd_request_args(params, &why)
	if (args == 0):
		return wbd_error_result(why)
	for char* a in args:
		# Anything that writes files or runs programs is not a query.
		if (starts_with(a, c"-o") || starts_with(a, c"--ptx") || starts_with(a, c"--debug")):
			return wbd_error_result(c"unsupported flag for a daemon query")
	char* key = wbd_key(sub, args)
	wbd_entry* hit = wbd_lookup(key)
	if (hit != 0):
		free(key)
		wbd_hits = wbd_hits + 1
		return wbd_output_result(hit.stdout_text, hit.stderr_text, hit.status, 1)
	wbd_misses = wbd_misses + 1
	process_result* result = wbd_run_tool(c"bin/wv2", sub, args, 0, 600000)
	if (result == 0):
		free(key)
		return wbd_error_result(c"could not run bin/wv2")
	if (result.status < 0):
		process_result_free(result)
		free(key)
		return wbd_error_result(c"bin/wv2 timed out or could not be waited for")
	# The deps run may itself be the closure entry this request needs.
	wbd_entry* again = wbd_lookup(key)
	if (again == 0):
		list[char*] closure = wbd_closure_for(args, key, result)
		again = wbd_lookup(key)
		if ((closure != 0) && (again == 0)):
			wbd_store(key, result, closure)
		else:
			free(key)
	else:
		free(key)
	json_value* answer = wbd_output_result(result.stdout_text, result.stderr_text, result.status, 0)
	process_result_free(result)
	return answer


json_value* wbd_handle_check(json_value* params, void* ctx):
	return wbd_serve_wv2(c"check", params)


json_value* wbd_handle_deps(json_value* params, void* ctx):
	return wbd_serve_wv2(c"deps", params)


json_value* wbd_handle_symbols(json_value* params, void* ctx):
	return wbd_serve_wv2(c"symbols", params)


json_value* wbd_handle_test_changed(json_value* params, void* ctx):
	wbd_requests = wbd_requests + 1
	wbd_touch()
	wbd_drain_events()
	char* why = 0
	list[char*] args = wbd_request_args(params, &why)
	if (args == 0):
		return wbd_error_result(why)
	for char* a in args:
		if (strcmp(a, c"--run") == 0):
			return wbd_error_result(c"--run executes builds; not served by the read-only daemon")
	char* stdin_text = 0
	json_value* input = json_object_get(params, c"stdin")
	if ((input != 0) && (input.type == json_type_string())):
		stdin_text = input.string_value
	wbd_prewarm_wait()
	wbd_misses = wbd_misses + 1
	process_result* result = wbd_run_tool(c"bin/wtest", c"changed", args, stdin_text, 0)
	if (result == 0):
		return wbd_error_result(c"could not run bin/wtest")
	if (result.status < 0):
		process_result_free(result)
		return wbd_error_result(c"bin/wtest could not be waited for")
	json_value* answer = wbd_output_result(result.stdout_text, result.stderr_text, result.status, 0)
	process_result_free(result)
	return answer


json_value* wbd_handle_status(json_value* params, void* ctx):
	wbd_touch()
	wbd_drain_events()
	json_value* result = json_object()
	json_object_set(result, c"protocol", json_int(wbd_protocol()))
	json_object_set(result, c"pid", json_int(getpid()))
	json_object_set(result, c"root", json_string(wbd_root))
	json_object_set(result, c"socket", json_string(wbd_socket_path))
	json_object_set(result, c"uptime_ms", json_int(time_monotonic_ms() - wbd_started_ms))
	json_object_set(result, c"cached_entries", json_int(wbd_cache.length))
	json_object_set(result, c"requests", json_int(wbd_requests))
	json_object_set(result, c"hits", json_int(wbd_hits))
	json_object_set(result, c"misses", json_int(wbd_misses))
	json_object_set(result, c"invalidations", json_int(wbd_invalidations))
	json_object_set(result, c"watched_dirs", json_int(wbd_watch_count))
	json_object_set(result, c"prewarm", json_string(wbd_prewarm_state()))
	json_object_set(result, c"prewarm_runs", json_int(wbd_prewarm_runs))
	json_object_set(result, c"builds", json_int(wbd_builds_done))
	json_object_set(result, c"builds_active", json_int(wbd_builds_active))
	json_object_set(result, c"warm_hashes", json_int(wexec_file_hashes.length))
	json_object_set(result, c"hashes_merged", json_int(wbd_hashes_merged))
	json_object_set(result, c"warm_manifest", json_bool(wexec_warm_manifest != 0))
	return result


json_value* wbd_handle_shutdown(json_value* params, void* ctx):
	wbd_begin_stop()
	return json_object()


# Stops listening right away (so 'stop' returns and a new daemon can
# bind the path), then exits once the builds in flight have answered.
void wbd_begin_stop():
	wbd_server.running = 0
	if (wbd_stopping == 0):
		wbd_stopping = 1
		if (wbd_listen_fd >= 0):
			event_loop_remove_fd(wbd_loop, wbd_listen_fd)
			close(wbd_listen_fd)
			wbd_listen_fd = -1
			unlink(wbd_socket_path)
	if (wbd_builds_active == 0):
		event_loop_stop(wbd_loop)


/* ---- connections ---- */

void wbd_conn_close(wbd_conn* c):
	if (c.open == 0):
		return
	c.open = 0
	if (c.watching):
		event_loop_remove_fd(wbd_loop, c.fd)
		c.watching = 0
	frame_reader_free(c.reader)
	c.reader = 0
	close(c.fd)
	for int fd in c.fds:
		close(fd)
	c.fds = new list[int]
	list[wbd_conn*] kept = new list[wbd_conn*]
	for wbd_conn* other in wbd_conns:
		if (other != c):
			kept.push(other)
	wbd_conns = kept


# frame_reader_fill, but through recvmsg so descriptors a client sends
# along with its request (SCM_RIGHTS) are collected, not dropped.
int wbd_conn_fill(wbd_conn* c):
	frame_reader* r = c.reader
	if (r.offset > 0):
		int i = 0
		while (r.offset + i < r.length):
			r.buffer[i] = r.buffer[r.offset + i]
			i = i + 1
		r.length = r.length - r.offset
		r.offset = 0
	if (r.length == r.capacity):
		int new_capacity = r.capacity * 2
		r.buffer = realloc(r.buffer, r.capacity, new_capacity)
		r.capacity = new_capacity
	int* got = malloc(8 * __word_size__)
	int count = 0
	int n = unix_recv_fds(c.fd, r.buffer + r.length, r.capacity - r.length, got, 8, &count)
	int i = 0
	while (i < count):
		c.fds.push(got[i])
		i = i + 1
	free(cast(char*, got))
	if (n > 0):
		r.length = r.length + n
	return n


void wbd_start_build(wbd_conn* c, json_value* message);


# One framed message: 'build' is answered asynchronously (when its
# child exits); everything else goes through lib/json_rpc.w's dispatch.
void wbd_dispatch(wbd_conn* c, char* body):
	json_value* message = json_parse(body)
	if ((message != 0) && (message.type == json_type_object())):
		json_value* method = json_object_get(message, c"method")
		if ((method != 0) && (method.type == json_type_string()) && (strcmp(method.string_value, c"build") == 0) && json_object_has(message, c"id")):
			wbd_start_build(c, message)
			json_free(message)
			return
	if (message != 0):
		json_free(message)
	jsonrpc_handle_body(wbd_server, body, c.fd)


void wbd_on_conn_readable(int fd, int revents, void* ctx):
	wbd_conn* c = cast(wbd_conn*, ctx)
	int count = wbd_conn_fill(c)
	# EAGAIN (-11) / EINTR (-4): nothing to read after all.
	if ((count == -11) || (count == -4)):
		return
	int drained = 0
	while ((drained == 0) && c.open):
		int length = 0
		char* body = frame_take_buffered_message(c.reader, &length)
		if (body == 0):
			drained = 1
		else:
			wbd_dispatch(c, body)
			free(body)
	if (c.open && (c.reader.error || (count <= 0))):
		if (c.building):
			# The client hung up (or broke framing) mid-build: stop
			# reading, keep the descriptor so the answer can still be
			# attempted, and let the build finish.
			if (c.watching):
				event_loop_remove_fd(wbd_loop, c.fd)
				c.watching = 0
		else:
			wbd_conn_close(c)
	if (wbd_server.running == 0):
		wbd_begin_stop()


# Accepted clients stay BLOCKING with a send timeout: lib/json_rpc.w's
# own listener makes them non-blocking, and a large answer (symbols of
# the whole compiler is megabytes) would then be cut short at the
# first EAGAIN inside write_all.
void wbd_on_listener(int fd, int revents, void* ctx):
	int client = socket_accept_connection(fd)
	if (client < 0):
		return
	socket_set_send_timeout(client, 30000)
	wbd_conn* c = new wbd_conn()
	c.fd = client
	c.reader = frame_reader_new(client)
	c.fds = new list[int]
	c.open = 1
	c.watching = 1
	c.building = 0
	wbd_conns.push(c)
	event_loop_add_fd(wbd_loop, client, poll_in(), wbd_on_conn_readable, cast(void*, c))


/* ---- build RPC ---- */

void wbd_set_cloexec(int fd):
	# F_SETFD (2), FD_CLOEXEC (1)
	sys_fcntl(fd, 2, 1)


void wbd_sigpipe_default():
	int* act = malloc(5 * __word_size__)
	act[0] = 0
	act[1] = 0
	act[2] = 0
	act[3] = 0
	act[4] = 0
	rt_sigaction(13, act, 0)
	free(act)


int wbd_umask(int mask):
	if (__word_size__ == 8):
		return syscall(95, mask, 0, 0)
	return syscall(60, mask, 0, 0)


char* wbd_read_fd_text(int fd):
	string_builder* s = string_new()
	char* buf = malloc(65536)
	int n = read(fd, buf, 65536)
	while (n > 0):
		string_append_bytes(s, buf, n)
		n = read(fd, buf, 65536)
	free(buf)
	char* text = s.data
	free(s)
	return text


int wbd_args_have(list[char*] args, char* flag):
	for char* a in args:
		if (strcmp(a, flag) == 0):
			return 1
	return 0


# Child side, before the executor runs: the default manifest. Warm, it
# is already parsed and only its generation's stderr is replayed.
# Cold, it is generated here with stderr captured, so the bytes can be
# replayed now and remembered; a failed generation is thrown away and
# left to wexec_load_manifest, which then fails exactly as one-shot.
# Returns the generated text when the daemon should keep it, else 0.
char* wbd_child_manifest(list[char*] args):
	if (wbd_args_have(args, c"-f")):
		return 0
	if (wexec_warm_manifest != 0):
		if (wbd_manifest_stderr != 0):
			write_all(2, wbd_manifest_stderr, strlen(wbd_manifest_stderr))
		return 0
	char* capture_path = strjoin(c"bin/.wbuildd.manifest_err.", itoa(getpid()))
	# O_RDWR | O_CREAT | O_TRUNC
	int capture = open(capture_path, 2 | 64 | 512, 384)
	unlink(capture_path)
	if (capture < 0):
		return 0
	# F_DUPFD (0): a spare copy of fd 2 to restore afterwards.
	int saved = sys_fcntl(2, 0, 10)
	dup2(capture, 2)
	int scan_tree = wexec_dirents_supported() || os_windows()
	char* text = manifest_source_text(0, scan_tree)
	dup2(saved, 2)
	close(saved)
	seek(capture, 0, 0)
	char* err_text = wbd_read_fd_text(capture)
	close(capture)
	if (text == 0):
		return 0
	json_value* parsed = json_parse(text)
	if (parsed == 0):
		return 0
	write_all(2, err_text, strlen(err_text))
	wexec_warm_manifest = parsed
	wexec_warm_manifest_label = manifest_source_label
	wbd_manifest_stderr = err_text
	return text


# The forked build child: becomes 'bin/wexec ARGS' in the client's
# stdio, environment and umask, runs the in-process executor, reports
# what it learned to the daemon, and exits with the executor's status.
void wbd_build_child(int* fds, list[char*] args, char** envp, int mask, int report_fd):
	wbd_sigpipe_default()
	dup2(fds[0], 0)
	dup2(fds[1], 1)
	dup2(fds[2], 2)
	# Nothing of the daemon's (listener, inotify, other clients' sockets
	# and build pipes) may leak into the build.
	int fd = 3
	while (fd < 1024):
		if (fd != report_fd):
			close(fd)
		fd = fd + 1
	if (mask >= 0):
		wbd_umask(mask)
	environ_ptr = cast(int, envp)
	char* manifest_text = wbd_child_manifest(args)
	char** argv = wbd_argv_from(c"bin/wexec", 0, args)
	int status = wexec_main(args.length + 1, cast(int, argv))
	json_value* report = json_object()
	json_value* hashes = json_object()
	for char* path, char* digest in wexec_file_hashes:
		if (wbd_hash_path_ok(path)):
			json_object_set(hashes, path, json_string(digest))
	json_object_set(report, c"hashes", hashes)
	if (manifest_text != 0):
		json_object_set(report, c"manifest", json_string(manifest_text))
		json_object_set(report, c"manifest_label", json_string(wexec_warm_manifest_label))
		json_object_set(report, c"manifest_stderr", json_string(wbd_manifest_stderr))
	char* text = json_stringify(report)
	write_all(report_fd, text, strlen(text))
	close(report_fd)
	exit(status)


void wbd_build_reply(wbd_conn* c, json_value* id, json_value* result):
	json_value* response = jsonrpc_response_result(id, result)
	jsonrpc_write_value(c.fd, response)
	json_free(response)


void wbd_build_refuse(wbd_conn* c, json_value* id, char* why):
	wbd_build_reply(c, json_clone(id), wbd_error_result(why))
	for int fd in c.fds:
		close(fd)
	c.fds = new list[int]


void wbd_on_build_report(int fd, int revents, void* ctx);


void wbd_start_build(wbd_conn* c, json_value* message):
	wbd_requests = wbd_requests + 1
	wbd_touch()
	wbd_drain_events()
	json_value* id = json_object_get(message, c"id")
	json_value* params = json_object_get(message, c"params")
	char* why = 0
	list[char*] args = wbd_request_args(params, &why)
	if (args == 0):
		wbd_build_refuse(c, id, why)
		return
	if (wbd_stopping):
		wbd_build_refuse(c, id, c"daemon is stopping")
		return
	if (c.building || (c.fds.length != 3)):
		wbd_build_refuse(c, id, c"a build needs the client's stdin, stdout and stderr descriptors")
		return
	json_value* env = json_object_get(params, c"env")
	if ((env == 0) || (env.type != json_type_array())):
		wbd_build_refuse(c, id, c"env must be an array")
		return
	char** envp = strv_new(json_array_length(env))
	int i = 0
	while (i < json_array_length(env)):
		json_value* entry = json_array_get(env, i)
		if (entry.type != json_type_string()):
			wbd_build_refuse(c, id, c"env entries must be strings")
			return
		strv_set(envp, i, entry.string_value)
		i = i + 1
	int mask = -1
	json_value* umask_value = json_object_get(params, c"umask")
	if ((umask_value != 0) && (umask_value.type == json_type_int())):
		mask = umask_value.int_value
	wbd_hashes_revalidate()
	int report_read = 0
	int report_write = 0
	if (process_make_pipe(&report_read, &report_write) != 0):
		wbd_build_refuse(c, id, c"cannot create the report pipe")
		return
	# The write end reaches the build child only: the programs its
	# steps exec must not hold it open past the child's exit.
	wbd_set_cloexec(report_read)
	wbd_set_cloexec(report_write)
	int* fds = malloc(3 * __word_size__)
	fds[0] = c.fds[0]
	fds[1] = c.fds[1]
	fds[2] = c.fds[2]
	wbd_seq = wbd_seq + 1
	int fork_seq = wbd_seq
	int pid = fork()
	if (pid == 0):
		wbd_build_child(fds, args, envp, mask, report_write)
	close(report_write)
	free(cast(char*, fds))
	for int passed in c.fds:
		close(passed)
	c.fds = new list[int]
	if (pid < 0):
		close(report_read)
		wbd_build_reply(c, json_clone(id), wbd_error_result(c"fork failed"))
		return
	c.building = 1
	wbd_builds_active = wbd_builds_active + 1
	wbd_build* b = new wbd_build()
	b.conn = c
	b.id = json_clone(id)
	b.pid = pid
	b.report_fd = report_read
	b.report = string_new()
	b.fork_seq = fork_seq
	event_loop_add_fd(wbd_loop, report_read, poll_in(), wbd_on_build_report, cast(void*, b))
	# Tells the client the build is running (and which process to
	# forward its signals to): from here on it must never fall back to
	# the one-shot command, which would run the build a second time.
	json_value* started = json_object()
	json_object_set(started, c"pid", json_int(pid))
	# (jsonrpc_write_notification frees started.)
	jsonrpc_write_notification(c.fd, c"build_started", started)


# A JSON string's text; the parser leaves an empty string's data 0.
char* wbd_json_text(json_value* v):
	if (v.string_value == 0):
		return c""
	return v.string_value


# Keeps what the child learned, minus anything an inotify event
# overtook after the fork.
void wbd_merge_report(wbd_build* b, json_value* report):
	if ((report == 0) || (report.type != json_type_object())):
		return
	json_value* hashes = json_object_get(report, c"hashes")
	if ((hashes != 0) && (hashes.type == json_type_object()) && (wbd_clear_seq <= b.fork_seq)):
		for char* path, json_value* digest in hashes.object_values:
			if ((digest.type != json_type_string()) || (wbd_hash_path_ok(path) == 0)):
				continue
			if (wbd_touched_since(path, b.fork_seq)):
				continue
			if (path in wexec_file_hashes):
				continue
			wexec_file_hashes[strclone(path)] = strclone(wbd_json_text(digest))
			wbd_hash_sig[strclone(path)] = wbd_file_sig(path)
			wbd_hashes_merged = wbd_hashes_merged + 1
	json_value* manifest = json_object_get(report, c"manifest")
	json_value* label = json_object_get(report, c"manifest_label")
	json_value* err = json_object_get(report, c"manifest_stderr")
	if ((manifest == 0) || (label == 0) || (err == 0)):
		return
	if ((manifest.type != json_type_string()) || (label.type != json_type_string()) || (err.type != json_type_string())):
		return
	if ((wbd_manifest_seq > b.fork_seq) || (wexec_warm_manifest != 0)):
		return
	json_value* parsed = json_parse(manifest.string_value)
	if (parsed == 0):
		return
	wexec_warm_manifest = parsed
	wexec_warm_manifest_label = strclone(wbd_json_text(label))
	wbd_manifest_stderr = strclone(wbd_json_text(err))


void wbd_on_build_report(int fd, int revents, void* ctx):
	wbd_build* b = cast(wbd_build*, ctx)
	char* buf = malloc(65536)
	int n = read(fd, buf, 65536)
	if (n > 0):
		string_append_bytes(b.report, buf, n)
	free(buf)
	if ((n > 0) || (n == -11) || (n == -4)):
		return
	# EOF: the child is exiting.
	event_loop_remove_fd(wbd_loop, fd)
	close(fd)
	int raw = 0
	wait4(b.pid, &raw, 0, 0)
	int status = process_decode_status(raw)
	# Events the build itself caused (its outputs) are applied first.
	wbd_drain_events()
	json_value* report = json_parse(b.report.data)
	wbd_merge_report(b, report)
	if (report != 0):
		json_free(report)
	string_free(b.report)
	wbd_builds_active = wbd_builds_active - 1
	wbd_builds_done = wbd_builds_done + 1
	if (wbd_builds_active == 0):
		wbd_touched = new map[char*, int]
		wbd_touched_dirs = new list[char*]
		wbd_touched_dir_seqs = new list[int]
	json_value* result = json_object()
	json_object_set(result, c"status", json_int(status))
	wbd_build_reply(b.conn, b.id, result)
	b.conn.building = 0
	wbd_conn_close(b.conn)
	wbd_touch()
	if (wbd_stopping):
		wbd_begin_stop()


# SIGPIPE -> SIG_IGN, so a client that disconnects mid-answer costs an
# EPIPE, not the daemon. struct sigaction is {handler, flags, restorer,
# mask...}; SIG_IGN needs no restorer on either word size.
void wbd_ignore_sigpipe():
	int* act = malloc(5 * __word_size__)
	act[0] = 1
	act[1] = 0
	act[2] = 0
	act[3] = 0
	act[4] = 0
	rt_sigaction(13, act, 0)
	free(act)


# The basename of our own executable when it lives in <root>/bin/, so
# inotify can tell the daemon its binary was rebuilt.
char* wbd_find_self_name():
	char* buf = malloc(4096)
	int n = file_readlink(c"/proc/self/exe", buf, 4095)
	if (n <= 0):
		return 0
	buf[n] = 0
	char* bin_dir = strjoin(wbd_root, c"/bin/")
	if (starts_with(buf, bin_dir) == 0):
		return 0
	char* name = buf + strlen(bin_dir)
	if (wbd_contains(name, c"/")):
		return 0
	return strclone(name)


struct wbd_serve_options:
	int prewarm
	char* prewarm_manifest
	char* log_path
	int detach
	int idle_timeout_ms


int wbd_serve(wbd_serve_options* o):
	if (o.log_path != 0):
		# O_WRONLY | O_CREAT | O_APPEND
		int log_fd = open(o.log_path, 1 | 64 | 1024, 420)
		if (log_fd >= 0):
			dup2(log_fd, 1)
			dup2(log_fd, 2)
			close(log_fd)
	if (o.detach):
		# setsid: leave the starting shell's session so its hangup
		# does not take the daemon down (x86 66, x64 112).
		if (__word_size__ == 8):
			syscall(112, 0, 0, 0)
		else:
			syscall(66, 0, 0, 0)
	wbd_ignore_sigpipe()
	wbd_root = wbd_cwd()
	wbd_started_ms = time_monotonic_ms()
	wbd_cache = new list[wbd_entry*]
	wbd_conns = new list[wbd_conn*]
	wbd_touched = new map[char*, int]
	wbd_touched_dirs = new list[char*]
	wbd_touched_dir_seqs = new list[int]
	wbd_hashes_clear()
	wbd_prewarm_enabled = o.prewarm
	wbd_prewarm_manifest = o.prewarm_manifest
	wbd_self_name = wbd_find_self_name()
	wbd_loop = event_loop_new()
	wbd_server = jsonrpc_server_new()
	jsonrpc_register(wbd_server, c"check", wbd_handle_check)
	jsonrpc_register(wbd_server, c"deps", wbd_handle_deps)
	jsonrpc_register(wbd_server, c"symbols", wbd_handle_symbols)
	jsonrpc_register(wbd_server, c"test_changed", wbd_handle_test_changed)
	jsonrpc_register(wbd_server, c"status", wbd_handle_status)
	jsonrpc_register(wbd_server, c"shutdown", wbd_handle_shutdown)
	mkdir(c"bin", 493)
	int listen_fd = socket_listen_unix_path(wbd_socket_path, 16)
	if (listen_fd < 0):
		wbd_err2(c"wbuildd: cannot listen on ", wbd_socket_path)
		return 1
	wbd_set_cloexec(listen_fd)
	wbd_listen_fd = listen_fd
	wbd_inotify_fd = -1
	wbd_rewatch()
	if (wbd_inotify_fd < 0):
		wbd_err(c"wbuildd: inotify unavailable (Linux only)\n")
		close(listen_fd)
		unlink(wbd_socket_path)
		return 1
	wbd_server.running = 1
	event_loop_add_fd(wbd_loop, listen_fd, poll_in(), wbd_on_listener, 0)
	wbd_prewarm_schedule(0)
	wbd_idle_timeout_ms = o.idle_timeout_ms
	wbd_touch()
	if (wbd_idle_timeout_ms > 0):
		event_loop_add_interval(wbd_loop, 1000, wbd_idle_check, 0)
	string_builder* banner = string_new()
	string_append(banner, c"wbuildd: serving ")
	string_append(banner, wbd_root)
	string_append(banner, c" on ")
	string_append(banner, wbd_socket_path)
	string_append(banner, c" (pid ")
	string_append_int(banner, getpid())
	string_append(banner, c", ")
	string_append_int(banner, wbd_watch_count)
	string_append(banner, c" directories watched)\n")
	wbd_err(banner.data)
	string_free(banner)
	event_loop_run(wbd_loop)
	if (wbd_prewarm_proc != 0):
		process_kill(wbd_prewarm_proc, sigterm())
		wbd_prewarm_wait()
	if (wbd_listen_fd >= 0):
		close(wbd_listen_fd)
		unlink(wbd_socket_path)
	wbd_err(c"wbuildd: stopped\n")
	return 0


/* ---- client ---- */

int wbd_connect():
	return socket_connect_unix_path(wbd_socket_path)


int wbd_connect_client();


# One request/response round trip on a fresh connection. Returns the
# owned "result" member, or 0 on any transport or protocol failure.
json_value* wbd_call(int fd, char* method, json_value* params):
	if (jsonrpc_write_request(fd, 1, method, params) < 0):
		return 0
	frame_reader* reader = frame_reader_new(fd)
	json_value* response = jsonrpc_read_message(reader)
	frame_reader_free(reader)
	if (response == 0):
		return 0
	if (response.type != json_type_object()):
		json_free(response)
		return 0
	json_value* result = json_object_get(response, c"result")
	if (result == 0):
		json_free(response)
		return 0
	json_value* owned = json_clone(result)
	json_free(response)
	return owned


json_value* wbd_call_simple(char* method):
	int fd = wbd_connect()
	if (fd < 0):
		return 0
	json_value* result = wbd_call(fd, method, json_object())
	close(fd)
	return result


# Runs the one-shot command in place of the daemon. With stdin_text 0
# the process is replaced (execve), so stdio, status and signals are
# exactly the one-shot command's; with already-consumed stdin the text
# is replayed through a pipe.
int wbd_oneshot(char* tool, char* sub, list[char*] args, char* stdin_text):
	char** argv = wbd_argv_from(tool, sub, args)
	if (stdin_text == 0):
		execve(tool, argv, env_current())
		wbd_err2(c"wbuildd: cannot run ", tool)
		return 127
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_pipe()
	process* p = process_spawn(tool, argv, opts)
	if (p == 0):
		wbd_err2(c"wbuildd: cannot run ", tool)
		return 127
	write_all(p.stdin_fd, stdin_text, strlen(stdin_text))
	process_close_stdin(p)
	return process_wait(p)


# Does a 'changed' argument list name any paths (or a range) itself?
# If not, bin/wtest reads them from stdin.
int wbd_changed_has_paths(list[char*] args):
	int i = 0
	while (i < args.length):
		char* a = args[i]
		if (strcmp(a, c"-f") == 0):
			i = i + 1
		else if (a[0] != '-'):
			return 1
		i = i + 1
	return 0


char* wbd_read_stdin():
	string_builder* s = string_new()
	char* buf = malloc(65536)
	int n = read(0, buf, 65536)
	while (n > 0):
		string_append_bytes(s, buf, n)
		n = read(0, buf, 65536)
	free(buf)
	char* text = s.data
	free(s)
	return text


int wbd_no_daemon
int wbd_require_daemon


int wbd_unreachable(char* why, char* tool, char* sub, list[char*] args, char* stdin_text):
	if (wbd_require_daemon):
		wbd_err2(c"wbuildd: daemon required but unavailable: ", why)
		return 2
	return wbd_oneshot(tool, sub, args, stdin_text)


int wbd_query(char* method, char* tool, char* sub, list[char*] args):
	if (wbd_no_daemon):
		return wbd_oneshot(tool, sub, args, 0)
	int reads_stdin = 0
	if (strcmp(method, c"test_changed") == 0):
		for char* a in args:
			if (strcmp(a, c"--run") == 0):
				return wbd_unreachable(c"--run is not served by the daemon", tool, sub, args, 0)
		reads_stdin = wbd_changed_has_paths(args) == 0
	int fd = wbd_connect_client()
	if (fd < 0):
		return wbd_unreachable(c"no daemon is listening", tool, sub, args, 0)
	char* stdin_text = 0
	if (reads_stdin):
		stdin_text = wbd_read_stdin()
	json_value* params = json_object()
	json_object_set(params, c"protocol", json_int(wbd_protocol()))
	char* cwd = wbd_cwd()
	json_object_set(params, c"cwd", json_string(cwd))
	free(cwd)
	json_value* list_json = json_array()
	for char* a in args:
		json_array_push(list_json, json_string(a))
	json_object_set(params, c"args", list_json)
	if (stdin_text != 0):
		json_object_set(params, c"stdin", json_string(stdin_text))
	# jsonrpc_write_request (inside wbd_call) frees params.
	json_value* result = wbd_call(fd, method, params)
	close(fd)
	if ((result == 0) || (result.type != json_type_object())):
		return wbd_unreachable(c"malformed response", tool, sub, args, stdin_text)
	json_value* error = json_object_get(result, c"error")
	if (error != 0):
		char* message = c"error response"
		if (error.type == json_type_string()):
			message = strclone(error.string_value)
		json_free(result)
		return wbd_unreachable(message, tool, sub, args, stdin_text)
	json_value* out = json_object_get(result, c"stdout")
	json_value* err = json_object_get(result, c"stderr")
	json_value* status = json_object_get(result, c"status")
	if ((out == 0) || (err == 0) || (status == 0) || (out.type != json_type_string()) || (err.type != json_type_string()) || (status.type != json_type_int())):
		json_free(result)
		return wbd_unreachable(c"malformed response", tool, sub, args, stdin_text)
	write_all(1, out.string_value, strlen(out.string_value))
	write_all(2, err.string_value, strlen(err.string_value))
	int code = status.int_value
	json_free(result)
	return code


int wbd_json_int(json_value* object, char* key):
	json_value* v = json_object_get(object, key)
	if ((v == 0) || (v.type != json_type_int())):
		return 0
	return v.int_value


int wbd_status_main(list[char*] args):
	int as_json = 0
	for char* a in args:
		if (strcmp(a, c"--json") == 0):
			as_json = 1
	json_value* result = wbd_call_simple(c"status")
	if (result == 0):
		wbd_err(c"wbuildd: not running\n")
		return 1
	if (as_json):
		char* text = json_stringify(result)
		wbd_out(text)
		wbd_out(c"\n")
		free(text)
		json_free(result)
		return 0
	string_builder* s = string_new()
	string_append(s, c"wbuildd: running (pid ")
	string_append_int(s, wbd_json_int(result, c"pid"))
	string_append(s, c")\nroot: ")
	json_value* root = json_object_get(result, c"root")
	if ((root != 0) && (root.type == json_type_string())):
		string_append(s, root.string_value)
	string_append(s, c"\nsocket: ")
	string_append(s, wbd_socket_path)
	string_append(s, c"\nuptime_ms: ")
	string_append_int(s, wbd_json_int(result, c"uptime_ms"))
	string_append(s, c"\ncached_entries: ")
	string_append_int(s, wbd_json_int(result, c"cached_entries"))
	string_append(s, c"\nrequests: ")
	string_append_int(s, wbd_json_int(result, c"requests"))
	string_append(s, c"\nhits: ")
	string_append_int(s, wbd_json_int(result, c"hits"))
	string_append(s, c"\nmisses: ")
	string_append_int(s, wbd_json_int(result, c"misses"))
	string_append(s, c"\ninvalidations: ")
	string_append_int(s, wbd_json_int(result, c"invalidations"))
	string_append(s, c"\nwatched_dirs: ")
	string_append_int(s, wbd_json_int(result, c"watched_dirs"))
	string_append(s, c"\nprewarm: ")
	json_value* prewarm = json_object_get(result, c"prewarm")
	if ((prewarm != 0) && (prewarm.type == json_type_string())):
		string_append(s, prewarm.string_value)
	string_append(s, c"\n")
	wbd_out(s.data)
	string_free(s)
	json_free(result)
	return 0


int wbd_stop_main():
	json_value* result = wbd_call_simple(c"shutdown")
	if (result == 0):
		wbd_err(c"wbuildd: not running\n")
		return 0
	json_free(result)
	# Wait until the listener is gone so a following 'start' binds cleanly.
	int waited = 0
	while (waited < 10000):
		int fd = wbd_connect()
		if (fd < 0):
			wbd_out(c"wbuildd: stopped\n")
			return 0
		close(fd)
		process_sleep_ms(50)
		waited = waited + 50
	wbd_err(c"wbuildd: daemon did not stop within 10s\n")
	return 1


char* wbd_self_path(char* argv0):
	char* buf = malloc(4096)
	int n = file_readlink(c"/proc/self/exe", buf, 4095)
	if (n <= 0):
		return argv0
	buf[n] = 0
	return buf


# Spawns 'serve --detach' with o's options; the process handle, or 0.
process* wbd_spawn_daemon(char* argv0, wbd_serve_options* o):
	char* self = wbd_self_path(argv0)
	list[char*] argv_list = new list[char*]
	argv_list.push(self)
	argv_list.push(c"--socket")
	argv_list.push(wbd_socket_path)
	argv_list.push(c"serve")
	argv_list.push(c"--detach")
	argv_list.push(c"--log")
	argv_list.push(o.log_path)
	if (o.prewarm == 0):
		argv_list.push(c"--no-prewarm")
	else if (o.prewarm_manifest != 0):
		argv_list.push(c"--prewarm-manifest")
		argv_list.push(o.prewarm_manifest)
	if (o.idle_timeout_ms > 0):
		argv_list.push(c"--idle-timeout-ms")
		argv_list.push(itoa(o.idle_timeout_ms))
	char** argv = strv_new(argv_list.length)
	int i = 0
	while (i < argv_list.length):
		strv_set(argv, i, argv_list[i])
		i = i + 1
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_null()
	opts.stdout_mode = process_null()
	opts.stderr_mode = process_null()
	process* p = process_spawn(self, argv, opts)
	free(cast(char*, opts))
	free(cast(char*, argv))
	return p


int wbd_start_main(char* argv0, wbd_serve_options* o):
	int probe = wbd_connect()
	if (probe >= 0):
		close(probe)
		wbd_out(c"wbuildd: already running\n")
		return 0
	process* p = wbd_spawn_daemon(argv0, o)
	if (p == 0):
		wbd_err(c"wbuildd: cannot spawn the daemon\n")
		return 1
	int waited = 0
	while (waited < 15000):
		int fd = wbd_connect()
		if (fd >= 0):
			close(fd)
			string_builder* s = string_new()
			string_append(s, c"wbuildd: started (pid ")
			string_append_int(s, p.pid)
			string_append(s, c", log ")
			string_append(s, o.log_path)
			string_append(s, c")\n")
			wbd_out(s.data)
			string_free(s)
			return 0
		if (process_try_wait(p) != process_status_running()):
			wbd_err2(c"wbuildd: daemon exited during startup; see ", o.log_path)
			return 1
		process_sleep_ms(50)
		waited = waited + 50
	wbd_err(c"wbuildd: daemon did not answer within 15s\n")
	return 1


/* ---- auto-start and the build client ---- */

int wbd_no_autostart
char* wbd_argv0


char* wbd_default_log():
	if (strcmp(wbd_socket_path, c"bin/.wbuildd.sock") == 0):
		return c"bin/.wbuildd.log"
	return strjoin(wbd_socket_path, c".log")


int wbd_env_is(char* name, char* value):
	char* text = env_get(name)
	if (text == 0):
		return 0
	return strcmp(text, value) == 0


# The client's connection: the running daemon, or else one this client
# starts (§2.2). Silent either way -- a query's output must stay exactly
# the one-shot command's -- and -1 means "fall back".
int wbd_connect_client():
	int fd = wbd_connect()
	if (fd >= 0):
		return fd
	if (wbd_no_autostart || wbd_env_is(c"WBUILDD_AUTOSTART", c"0")):
		return -1
	# Only from a checkout root: never watch an arbitrary tree.
	int probe = open(c"build.base.json", 0, 0)
	if (probe < 0):
		return -1
	close(probe)
	wbd_serve_options* o = new wbd_serve_options()
	o.prewarm = wbd_env_is(c"WBUILDD_PREWARM", c"0") == 0
	o.prewarm_manifest = 0
	o.log_path = wbd_default_log()
	o.detach = 1
	o.idle_timeout_ms = 3600000
	char* idle = env_get(c"WBUILDD_IDLE_TIMEOUT_MS")
	if ((idle != 0) && (atoi(idle) > 0)):
		o.idle_timeout_ms = atoi(idle)
	process* p = wbd_spawn_daemon(wbd_argv0, o)
	if (p == 0):
		return -1
	int waited = 0
	while (waited < 15000):
		fd = wbd_connect()
		if (fd >= 0):
			return fd
		if (process_try_wait(p) != process_status_running()):
			# Lost a start race to another client's daemon, or failed
			# (see the log): one last look, then fall back.
			return wbd_connect()
		process_sleep_ms(20)
		waited = waited + 20
	return -1


int wbd_build_pid


# SIGINT/SIGTERM/SIGHUP reach the build child, whose wexec handler
# kills its workers' process groups and exits 128+signal -- the status
# the daemon then reports back, as a one-shot run would have exited.
void wbd_forward_signal(int sig):
	if (wbd_build_pid > 0):
		kill(wbd_build_pid, sig)


# 'build ARGS' == 'bin/wexec ARGS', run by the daemon in this process's
# own stdin/stdout/stderr.
int wbd_build_main(list[char*] args):
	char* tool = c"bin/wexec"
	if (wbd_no_daemon):
		return wbd_oneshot(tool, 0, args, 0)
	int k = 0
	while (k < 3):
		# F_GETFD: all three standard descriptors must exist to be passed.
		if (sys_fcntl(k, 1, 0) < 0):
			return wbd_unreachable(c"a standard descriptor is closed", tool, 0, args, 0)
		k = k + 1
	int fd = wbd_connect_client()
	if (fd < 0):
		return wbd_unreachable(c"no daemon is listening", tool, 0, args, 0)
	json_value* params = json_object()
	json_object_set(params, c"protocol", json_int(wbd_protocol()))
	char* cwd = wbd_cwd()
	json_object_set(params, c"cwd", json_string(cwd))
	free(cwd)
	json_value* list_json = json_array()
	for char* a in args:
		json_array_push(list_json, json_string(a))
	json_object_set(params, c"args", list_json)
	json_value* env = json_array()
	char** envp = env_current()
	int e = 0
	while (e < env_vector_count(envp)):
		json_array_push(env, json_string(strv_get(envp, e)))
		e = e + 1
	json_object_set(params, c"env", env)
	int mask = wbd_umask(0)
	wbd_umask(mask)
	json_object_set(params, c"umask", json_int(mask))
	json_value* request = jsonrpc_request_new(1, c"build", params)
	char* body = json_stringify(request)
	string_builder* frame = string_new()
	string_append(frame, c"Content-Length: ")
	string_append_int(frame, strlen(body))
	string_append(frame, c"\r\n\r\n")
	string_append(frame, body)
	int* stdio = malloc(3 * __word_size__)
	stdio[0] = 0
	stdio[1] = 1
	stdio[2] = 2
	int sent = unix_send_fds(fd, frame.data, frame.length, stdio, 3)
	if ((sent > 0) && (sent < frame.length)):
		if (write_all(fd, frame.data + sent, frame.length - sent) < 0):
			sent = -1
	if (sent <= 0):
		close(fd)
		return wbd_unreachable(c"could not send the build request", tool, 0, args, 0)
	frame_reader* reader = frame_reader_new(fd)
	int started = 0
	while (1):
		int length = 0
		char* message_text = frame_take_buffered_message(reader, &length)
		if (message_text == 0):
			if (reader.error):
				break
			int count = frame_reader_fill(reader)
			# EINTR: a signal was forwarded; keep waiting for the answer.
			if (count == -4):
				continue
			if (count <= 0):
				break
			continue
		json_value* message = json_parse(message_text)
		free(message_text)
		if ((message == 0) || (message.type != json_type_object())):
			break
		json_value* method = json_object_get(message, c"method")
		if ((method != 0) && (method.type == json_type_string()) && (strcmp(method.string_value, c"build_started") == 0)):
			json_value* started_params = json_object_get(message, c"params")
			wbd_build_pid = wbd_json_int(started_params, c"pid")
			if (started == 0):
				started = 1
				wexec_install_termination_handler(cast(int, wbd_forward_signal))
			continue
		json_value* result = json_object_get(message, c"result")
		if ((result == 0) || (result.type != json_type_object())):
			break
		json_value* status = json_object_get(result, c"status")
		if ((status != 0) && (status.type == json_type_int())):
			close(fd)
			return status.int_value
		json_value* error = json_object_get(result, c"error")
		if ((error != 0) && (error.type == json_type_string()) && (started == 0)):
			close(fd)
			return wbd_unreachable(strclone(error.string_value), tool, 0, args, 0)
		break
	close(fd)
	if (started):
		# The build ran (its output already reached our stdout/stderr);
		# running it again one-shot would repeat it. Report, don't retry.
		wbd_err(c"wbuildd: lost the daemon before the build reported its status\n")
		return 1
	return wbd_unreachable(c"malformed response", tool, 0, args, 0)


void wbd_usage():
	wbd_err(c"usage: wbuildd [--socket PATH] [--no-daemon|--require-daemon] [--no-autostart] <command> [args...]\n")
	wbd_err(c"  serve|start [--prewarm-manifest M | --no-prewarm] [--log FILE] [--idle-timeout-ms N]\n")
	wbd_err(c"  stop | status [--json]                                           control it\n")
	wbd_err(c"  check|deps|symbols ARGS   == bin/wv2 check|deps|symbols ARGS\n")
	wbd_err(c"  changed ARGS              == bin/wtest changed ARGS\n")
	wbd_err(c"  build ARGS                == bin/wexec ARGS\n")


int main(int argc, int argv):
	wbd_socket_path = c"bin/.wbuildd.sock"
	wbd_argv0 = wbd_arg(argv, 0)
	char* env_switch = env_get(c"WBUILDD")
	if ((env_switch != 0) && (strcmp(env_switch, c"0") == 0)):
		wbd_no_daemon = 1
	int i = 1
	while ((i < argc) && (wbd_arg(argv, i)[0] == '-')):
		char* flag = wbd_arg(argv, i)
		if ((strcmp(flag, c"--socket") == 0) && (i + 1 < argc)):
			i = i + 1
			wbd_socket_path = wbd_arg(argv, i)
		else if (strcmp(flag, c"--no-daemon") == 0):
			wbd_no_daemon = 1
		else if (strcmp(flag, c"--require-daemon") == 0):
			wbd_require_daemon = 1
		else if (strcmp(flag, c"--no-autostart") == 0):
			wbd_no_autostart = 1
		else:
			wbd_usage()
			return 2
		i = i + 1
	if (i >= argc):
		wbd_usage()
		return 2
	char* command = wbd_arg(argv, i)
	list[char*] rest = new list[char*]
	i = i + 1
	while (i < argc):
		rest.push(wbd_arg(argv, i))
		i = i + 1
	if (strcmp(command, c"check") == 0):
		return wbd_query(c"check", c"bin/wv2", c"check", rest)
	if (strcmp(command, c"deps") == 0):
		return wbd_query(c"deps", c"bin/wv2", c"deps", rest)
	if (strcmp(command, c"symbols") == 0):
		return wbd_query(c"symbols", c"bin/wv2", c"symbols", rest)
	if (strcmp(command, c"changed") == 0):
		return wbd_query(c"test_changed", c"bin/wtest", c"changed", rest)
	if (strcmp(command, c"build") == 0):
		return wbd_build_main(rest)
	if (strcmp(command, c"status") == 0):
		return wbd_status_main(rest)
	if (strcmp(command, c"stop") == 0):
		return wbd_stop_main()
	if ((strcmp(command, c"serve") == 0) || (strcmp(command, c"start") == 0)):
		wbd_serve_options* o = new wbd_serve_options()
		o.prewarm = 1
		o.prewarm_manifest = 0
		o.log_path = 0
		o.detach = 0
		o.idle_timeout_ms = 0
		int j = 0
		while (j < rest.length):
			char* opt = rest[j]
			if ((strcmp(opt, c"--prewarm-manifest") == 0) && (j + 1 < rest.length)):
				j = j + 1
				o.prewarm_manifest = rest[j]
			else if (strcmp(opt, c"--no-prewarm") == 0):
				o.prewarm = 0
			else if ((strcmp(opt, c"--log") == 0) && (j + 1 < rest.length)):
				j = j + 1
				o.log_path = rest[j]
			else if ((strcmp(opt, c"--idle-timeout-ms") == 0) && (j + 1 < rest.length)):
				j = j + 1
				o.idle_timeout_ms = atoi(rest[j])
			else if (strcmp(opt, c"--detach") == 0):
				o.detach = 1
			else:
				wbd_usage()
				return 2
			j = j + 1
		if (strcmp(command, c"serve") == 0):
			return wbd_serve(o)
		if (o.log_path == 0):
			o.log_path = c"bin/.wbuildd.log"
		return wbd_start_main(wbd_arg(argv, 0), o)
	wbd_usage()
	return 2
