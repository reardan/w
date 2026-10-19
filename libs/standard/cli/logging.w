/*
Leveled logging, after Python's `logging` (docs/projects/stdlib_python_parity.md
chunk P2.5). This module replaces lib/logging.w, which is an early
sketch with a hard-coded timestamp; that file keeps working unchanged
for its existing callers, but new code should import this one.

Levels are ints, as in Python: LOG_NOTSET (0), LOG_DEBUG (10), LOG_INFO
(20), LOG_WARNING (30), LOG_ERROR (40), LOG_CRITICAL (50). Any other
value works too and is named "Level N".

Loggers are named and hierarchical: log_get_logger(c"a.b") returns the
same logger every time, creating it (and its ancestors "a") on first
use; its parent is "a", whose parent is the root logger (log_root(),
named "root", level LOG_WARNING). A logger whose level is LOG_NOTSET
takes its effective level from the nearest ancestor with a level set.
A record that passes the logger's effective level is offered to the
handlers of the logger and then of each ancestor, stopping after the
first logger whose propagate flag is 0; each handler applies its own
level threshold. When no handler is found at all, records at
LOG_WARNING or above print their bare message on stderr (Python's
"last resort" handler).

Handlers are a small interface (an emit and an optional close function
plus a self pointer, see log_handler_new) with three built-ins:
log_stream_handler_new(fd) / log_stderr_handler_new() write to a
descriptor, log_file_handler_new(path) appends to a file, and
log_memory_handler_new() keeps the formatted lines for tests.

Formats use Python's %(field)s placeholders: asctime ("YYYY-MM-DD
HH:MM:SS", UTC, from lib/time.w), created (unix seconds), name,
levelname, levelno and message; "%%" is a literal percent sign and an
unknown placeholder is copied through unchanged. The width/flag forms
("%(name)-8s") are not supported. The default is log_default_format().
The clock is injectable with log_set_clock so tests are deterministic.

Locking uses lib/task_sync.w: the registry and each handler have a
task_mutex, wrapped in a re-entrant lock owned by the calling task (or
the main program outside any task), so a handler that logs again does
not deadlock and tasks on one scheduler never interleave lines. This
does not make the module safe for OS threads that share loggers
without their own locking (task_mutex is a scheduler-level lock).

Ownership: the module owns every logger and handler. log_handler_free
detaches a handler from all loggers, closes and frees it;
log_shutdown() closes and frees every handler and logger and resets
the module to its initial state.
*/
import lib.lib
import lib.io
import lib.fs
import lib.time
import lib.task
import lib.task_sync
import lib.str
import structures.string


const int LOG_NOTSET = 0
const int LOG_DEBUG = 10
const int LOG_INFO = 20
const int LOG_WARNING = 30
const int LOG_ERROR = 40
const int LOG_CRITICAL = 50

# O_APPEND in lib/file_ops.w's portable (Linux generic) flag numbering.
const int LOG_O_APPEND = 1024


char* log_default_format():
	return c"%(asctime)s %(levelname)s %(name)s: %(message)s"


/* Re-entrant lock over a task_mutex. */

struct log_lock:
	task_mutex* mutex
	void* owner     # task_active_get() of the holder; 0 = main program
	int depth


log_lock* log_lock_new():
	log_lock* l = new log_lock()
	l.mutex = task_mutex_new()
	l.owner = 0
	l.depth = 0
	return l


void log_lock_free(log_lock* l):
	task_mutex_free(l.mutex)
	free(cast(void*, l))


# 1 when the lock is now held (call log_lock_release later), 0 when it
# could not be taken (a cancelled or timed-out task wait).
int log_lock_acquire(log_lock* l):
	void* me = cast(void*, task_active_get())
	if ((l.depth > 0) && (l.owner == me)):
		l.depth = l.depth + 1
		return 1
	if (task_mutex_try_lock(l.mutex) == 0):
		# Held by someone else. Only a task can wait for it; the main
		# program outside the scheduler cannot park, and nothing else
		# can run while it holds the CPU, so it just proceeds.
		if (task_in_task() == 0):
			l.depth = l.depth + 1
			return 1
		if (task_mutex_lock(l.mutex) != 0): return 0
	l.owner = me
	l.depth = 1
	return 1


void log_lock_release(log_lock* l):
	l.depth = l.depth - 1
	if (l.depth == 0):
		l.owner = 0
		task_mutex_unlock(l.mutex)


/* Records and handlers. */

struct log_record:
	char* name        # logger name ("root" for the root logger)
	int level
	char* message
	int created       # unix seconds from the module clock


# self, record, formatted line (no trailing newline)
type log_emit_fn = fn(void*, log_record*, char*) -> void
# self
type log_close_fn = fn(void*) -> void


struct log_handler:
	void* self
	log_emit_fn* emit
	log_close_fn* close
	int level
	char* format          # owned copy
	log_lock* lock
	# built-in handler state
	int fd
	int owns_fd
	int errors            # failed writes (stream/file handlers)
	list[char*] lines     # memory handler: owned formatted lines
	list[int] levels      # memory handler: the level of each line


struct logger:
	char* name            # owned
	int level
	int propagate
	int disabled
	logger* parent
	list[log_handler*] handlers


type log_clock_fn = fn() -> int


struct log_manager:
	map[char*, logger*] loggers
	list[log_handler*] all_handlers
	logger* root
	log_lock* lock
	log_clock_fn* clock
	int disable_level     # records at or below are dropped (log_disable)


log_manager* log_state


int log_clock_default():
	return time_now()


log_manager* log_manager_get():
	if (cast(int, log_state) != 0): return log_state
	log_manager* m = new log_manager()
	m.loggers = new map[char*, logger*]
	m.all_handlers = new list[log_handler*]
	m.lock = log_lock_new()
	m.clock = 0
	m.disable_level = LOG_NOTSET - 1
	logger* root = new logger()
	root.name = strclone(c"root")
	root.level = LOG_WARNING
	root.propagate = 1
	root.disabled = 0
	root.parent = 0
	root.handlers = new list[log_handler*]
	m.root = root
	log_state = m
	return m


/* Levels. */

# "DEBUG" .. "CRITICAL", "NOTSET", or 0 for any other level.
char* log_level_name(int level):
	if (level == LOG_CRITICAL): return c"CRITICAL"
	if (level == LOG_ERROR): return c"ERROR"
	if (level == LOG_WARNING): return c"WARNING"
	if (level == LOG_INFO): return c"INFO"
	if (level == LOG_DEBUG): return c"DEBUG"
	if (level == LOG_NOTSET): return c"NOTSET"
	return 0


# The level named by s (as log_level_name spells it, plus Python's
# aliases "WARN" and "FATAL"), or -1. Case-sensitive, like Python.
int log_level_from_name(char* s):
	if (cast(int, s) == 0): return -1
	if (strcmp(s, c"CRITICAL") == 0): return LOG_CRITICAL
	if (strcmp(s, c"FATAL") == 0): return LOG_CRITICAL
	if (strcmp(s, c"ERROR") == 0): return LOG_ERROR
	if (strcmp(s, c"WARNING") == 0): return LOG_WARNING
	if (strcmp(s, c"WARN") == 0): return LOG_WARNING
	if (strcmp(s, c"INFO") == 0): return LOG_INFO
	if (strcmp(s, c"DEBUG") == 0): return LOG_DEBUG
	if (strcmp(s, c"NOTSET") == 0): return LOG_NOTSET
	return -1


void log_append_level_name(string_builder* sb, int level):
	char* name = log_level_name(level)
	if (cast(int, name) != 0):
		string_append(sb, name)
		return
	string_append(sb, c"Level ")
	string_append_int(sb, level)


/* Clock and global switches. */

# Installs the timestamp source (unix seconds); 0 restores time_now.
void log_set_clock(log_clock_fn* clock):
	log_manager_get().clock = clock


int log_clock_now():
	log_manager* m = log_manager_get()
	if (cast(int, m.clock) != 0): return m.clock()
	return log_clock_default()


# Python's logging.disable: drops every record at or below level on all
# loggers. log_disable(LOG_NOTSET) re-enables everything.
void log_disable(int level):
	log_manager* m = log_manager_get()
	if (level == LOG_NOTSET): m.disable_level = LOG_NOTSET - 1
	else: m.disable_level = level


/* Formatting. */

int log_starts_with(char* s, char* prefix):
	int i = 0
	while (prefix[i] != 0):
		if (s[i] != prefix[i]): return 0
		i = i + 1
	return 1


# Appends the expansion of fmt for r to sb.
void log_format_into(string_builder* sb, char* fmt, log_record* r):
	int i = 0
	while (fmt[i] != 0):
		char c = fmt[i]
		if ((c == '%') && (fmt[i + 1] == '%')):
			string_append_char(sb, '%')
			i = i + 2
			continue
		if ((c == '%') && (fmt[i + 1] == '(')):
			char* p = &fmt[i]
			int handled = 1
			int skip = 0
			if (log_starts_with(p, c"%(asctime)s")):
				char* ts = time_format_unix_utc(r.created)
				string_append(sb, ts)
				free(ts)
				skip = 11
			else if (log_starts_with(p, c"%(created)s")):
				string_append_int(sb, r.created)
				skip = 11
			else if (log_starts_with(p, c"%(name)s")):
				string_append(sb, r.name)
				skip = 8
			else if (log_starts_with(p, c"%(levelname)s")):
				log_append_level_name(sb, r.level)
				skip = 13
			else if (log_starts_with(p, c"%(levelno)s")):
				string_append_int(sb, r.level)
				skip = 11
			else if (log_starts_with(p, c"%(levelno)d")):
				string_append_int(sb, r.level)
				skip = 11
			else if (log_starts_with(p, c"%(created)d")):
				string_append_int(sb, r.created)
				skip = 11
			else if (log_starts_with(p, c"%(message)s")):
				string_append(sb, r.message)
				skip = 11
			else:
				handled = 0
			if (handled):
				i = i + skip
				continue
		string_append_char(sb, c)
		i = i + 1


# A malloc'd expansion of fmt (log_default_format() when 0) for r.
char* log_format_record(char* fmt, log_record* r):
	if (cast(int, fmt) == 0): fmt = log_default_format()
	string_builder* sb = string_new()
	log_format_into(sb, fmt, r)
	char* out = sb.data
	free(cast(void*, sb))
	return out


/* Handlers. */

# A custom handler: emit(self, record, line) is called with the line
# already formatted by the handler's format; close(self), if non-zero,
# runs once when the handler is freed. The handler starts at LOG_NOTSET
# (passes everything its logger lets through).
log_handler* log_handler_new(void* self, log_emit_fn* emit, log_close_fn* close):
	log_manager* m = log_manager_get()
	log_handler* h = new log_handler()
	h.self = self
	h.emit = emit
	h.close = close
	h.level = LOG_NOTSET
	h.format = strclone(log_default_format())
	h.lock = log_lock_new()
	h.fd = -1
	h.owns_fd = 0
	h.errors = 0
	h.lines = 0
	h.levels = 0
	if (log_lock_acquire(m.lock)):
		m.all_handlers.push(h)
		log_lock_release(m.lock)
	return h


void log_handler_set_level(log_handler* h, int level):
	h.level = level


# Replaces the handler's format (copied); 0 restores the default.
void log_handler_set_format(log_handler* h, char* fmt):
	if (cast(int, fmt) == 0): fmt = log_default_format()
	char* copy = strclone(fmt)
	free(h.format)
	h.format = copy


void log_fd_emit(void* self, log_record* r, char* line):
	log_handler* h = cast(log_handler*, self)
	io_result res
	if (io_write_all(h.fd, line, strlen(line), &res) != IO_OK):
		h.errors = h.errors + 1
		return
	if (io_write_all(h.fd, c"\n", 1, &res) != IO_OK):
		h.errors = h.errors + 1


void log_fd_close(void* self):
	log_handler* h = cast(log_handler*, self)
	if (h.owns_fd && (h.fd >= 0)):
		io_result res
		io_close(h.fd, &res)
	h.fd = -1


# Writes each record as a line on fd; the caller keeps owning fd.
log_handler* log_stream_handler_new(int fd):
	log_handler* h = log_handler_new(0, log_fd_emit, log_fd_close)
	h.self = cast(void*, h)
	h.fd = fd
	return h


log_handler* log_stderr_handler_new():
	return log_stream_handler_new(2)


# Appends each record as a line to path, creating it (rw-r--r--) when
# missing. Returns 0 when the file cannot be opened.
log_handler* log_file_handler_new(char* path):
	io_result res
	int flags = FS_O_WRONLY | FS_O_CREAT | LOG_O_APPEND | FS_O_CLOEXEC
	int fd = fs_open(path, flags, FS_DEFAULT_MODE, &res)
	if (fd < 0): return 0
	log_handler* h = log_stream_handler_new(fd)
	h.owns_fd = 1
	return h


# Count of failed writes on a stream or file handler.
int log_handler_errors(log_handler* h):
	return h.errors


void log_memory_emit(void* self, log_record* r, char* line):
	log_handler* h = cast(log_handler*, self)
	h.lines.push(strclone(line))
	h.levels.push(r.level)


void log_memory_clear(log_handler* h):
	for i in range(h.lines.length):
		free(h.lines[i])
	h.lines.clear()
	h.levels.clear()


void log_memory_close(void* self):
	log_handler* h = cast(log_handler*, self)
	log_memory_clear(h)
	h.lines.free()
	h.levels.free()
	h.lines = 0
	h.levels = 0


# Keeps every formatted line in memory, for tests.
log_handler* log_memory_handler_new():
	log_handler* h = log_handler_new(0, log_memory_emit, log_memory_close)
	h.self = cast(void*, h)
	h.lines = new list[char*]
	h.levels = new list[int]
	return h


int log_memory_count(log_handler* h):
	return h.lines.length


# The i-th captured line (owned by the handler) or its level.
char* log_memory_line(log_handler* h, int i):
	return h.lines[i]


int log_memory_level(log_handler* h, int i):
	return h.levels[i]


void log_handler_remove_from(logger* lg, log_handler* h):
	int i = 0
	while (i < lg.handlers.length):
		if (lg.handlers[i] == h): lg.handlers.remove(i)
		else: i = i + 1


void log_handler_destroy(log_handler* h):
	if (cast(int, h.close) != 0): h.close(h.self)
	free(h.format)
	log_lock_free(h.lock)
	free(cast(void*, h))


# Detaches h from every logger, closes and frees it.
void log_handler_free(log_handler* h):
	log_manager* m = log_manager_get()
	int locked = log_lock_acquire(m.lock)
	log_handler_remove_from(m.root, h)
	for char* name, logger* lg in m.loggers:
		log_handler_remove_from(lg, h)
	int i = 0
	while (i < m.all_handlers.length):
		if (m.all_handlers[i] == h): m.all_handlers.remove(i)
		else: i = i + 1
	if (locked): log_lock_release(m.lock)
	log_handler_destroy(h)


/* Loggers. */

logger* log_root():
	return log_manager_get().root


logger* log_logger_new(char* name, logger* parent):
	logger* lg = new logger()
	lg.name = strclone(name)
	lg.level = LOG_NOTSET
	lg.propagate = 1
	lg.disabled = 0
	lg.parent = parent
	lg.handlers = new list[log_handler*]
	return lg


# The logger named name, created on first use. 0, "" and "root" name
# the root logger. "a.b.c" also creates "a" and "a.b" so the parent
# chain is complete.
logger* log_get_logger(char* name):
	log_manager* m = log_manager_get()
	if (cast(int, name) == 0): return m.root
	if (name[0] == 0): return m.root
	if (strcmp(name, c"root") == 0): return m.root
	int locked = log_lock_acquire(m.lock)
	logger* parent = m.root
	logger* found = 0
	int n = strlen(name)
	int i = 0
	while (i <= n):
		if ((name[i] == '.') || (i == n)):
			char* prefix = str_copy_range(name, 0, i)
			if (prefix in m.loggers):
				found = m.loggers[prefix]
			else:
				found = log_logger_new(prefix, parent)
				m.loggers[prefix] = found
			free(prefix)
			parent = found
		i = i + 1
	if (locked): log_lock_release(m.lock)
	return found


# The logger's own child: log_get_child(a, "b") is log_get_logger("a.b").
logger* log_get_child(logger* lg, char* suffix):
	if (lg == log_root()): return log_get_logger(suffix)
	char* dotted = strjoin(lg.name, c".")
	char* full = strjoin(dotted, suffix)
	free(dotted)
	logger* child = log_get_logger(full)
	free(full)
	return child


void log_set_level(logger* lg, int level):
	lg.level = level


void log_set_propagate(logger* lg, int propagate):
	lg.propagate = propagate


void log_set_disabled(logger* lg, int disabled):
	lg.disabled = disabled


# The first level set on lg or an ancestor (LOG_NOTSET only if even the
# root has none).
int log_effective_level(logger* lg):
	logger* c = lg
	while (cast(int, c) != 0):
		if (c.level != LOG_NOTSET): return c.level
		c = c.parent
	return LOG_NOTSET


# 1 when a record at level would be handled (Python's isEnabledFor).
int log_is_enabled_for(logger* lg, int level):
	if (lg.disabled): return 0
	if (level <= log_manager_get().disable_level): return 0
	return level >= log_effective_level(lg)


void log_add_handler(logger* lg, log_handler* h):
	for i in range(lg.handlers.length):
		if (lg.handlers[i] == h): return
	lg.handlers.push(h)


void log_remove_handler(logger* lg, log_handler* h):
	log_handler_remove_from(lg, h)


# 1 when lg or an ancestor reached through propagate has a handler.
int log_has_handlers(logger* lg):
	logger* c = lg
	while (cast(int, c) != 0):
		if (c.handlers.length > 0): return 1
		if (c.propagate == 0): return 0
		c = c.parent
	return 0


void log_handle(log_handler* h, log_record* r):
	if (r.level < h.level): return
	if (log_lock_acquire(h.lock) == 0): return
	char* line = log_format_record(h.format, r)
	h.emit(h.self, r, line)
	free(line)
	log_lock_release(h.lock)


# Logs message at level on lg (Python's Logger.log).
void log_log(logger* lg, int level, char* message):
	if (log_is_enabled_for(lg, level) == 0): return
	log_record r
	r.name = lg.name
	r.level = level
	r.message = message
	r.created = log_clock_now()
	int found = 0
	logger* c = lg
	while (cast(int, c) != 0):
		for i in range(c.handlers.length):
			found = found + 1
			log_handle(c.handlers[i], &r)
		if (c.propagate == 0): break
		c = c.parent
	if ((found == 0) && (level >= LOG_WARNING)):
		io_result res
		io_write_all(2, message, strlen(message), &res)
		io_write_all(2, c"\n", 1, &res)


void log_debug(logger* lg, char* message):
	log_log(lg, LOG_DEBUG, message)


void log_info(logger* lg, char* message):
	log_log(lg, LOG_INFO, message)


void log_warning(logger* lg, char* message):
	log_log(lg, LOG_WARNING, message)


void log_error(logger* lg, char* message):
	log_log(lg, LOG_ERROR, message)


void log_critical(logger* lg, char* message):
	log_log(lg, LOG_CRITICAL, message)


# Python's logging.basicConfig: when the root logger has no handlers,
# gives it a stderr handler with fmt (0 = log_default_format()) and sets its level.
# Returns the new handler, or 0 when root already had one.
log_handler* log_basic_config(int level, char* fmt):
	logger* root = log_root()
	if (root.handlers.length > 0): return 0
	log_handler* h = log_stderr_handler_new()
	log_handler_set_format(h, fmt)
	log_add_handler(root, h)
	log_set_level(root, level)
	return h


void log_logger_destroy(logger* lg):
	lg.handlers.free()
	free(lg.name)
	free(cast(void*, lg))


# Closes and frees every handler and logger; the next call into the
# module starts from a fresh root (level LOG_WARNING, no handlers,
# default clock).
void log_shutdown():
	if (cast(int, log_state) == 0): return
	log_manager* m = log_state
	for i in range(m.all_handlers.length):
		log_handler_destroy(m.all_handlers[i])
	m.all_handlers.free()
	for char* name, logger* lg in m.loggers:
		log_logger_destroy(lg)
	m.loggers.free()
	log_logger_destroy(m.root)
	log_lock_free(m.lock)
	free(cast(void*, m))
	log_state = 0
