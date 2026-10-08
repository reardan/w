/*
In-memory filesystem with crash simulation and fault injection behind
the lib/file_ops.w table (docs/projects/simulation.md, issue #514 stage
W4). Storage code written against file_ops runs here unchanged; a test
then crashes the "machine" and checks what recovery sees.

State model. Every file (inode) has two copies of its contents:
- volatile: what reads see - every completed write;
- durable: what survives a crash - as of the last successful sync,
plus the list of changes (writes, truncations) issued since, in order.
The namespace (path -> inode) likewise has a volatile view and a durable
view plus a list of unsynced directory operations (create, mkdir,
rename, unlink), in issue order.

- file_ops_sync / datasync applies the file's pending changes to its
  durable copy. It does NOT make the file's name durable.
- file_ops_sync_dir(d) commits the pending directory operations up to
  and including the last one that touched d (an ordered metadata
  journal, as ext4 and xfs commit: syncing d also commits any earlier
  metadata change, never a later one). Syncing a directory fd behaves
  the same way.
- A sync that fails with an injected EIO drops the file's pending
  changes without applying them (Linux marks the dirty pages clean after
  reporting writeback errors): reads still see the data, a crash loses
  it, and a later successful sync does not bring it back.

fake_fs_crash(fs, rng) simulates power loss: descriptors are invalidated,
then from the durable state a seeded, permitted subset of the volatile
state survives:
- directory operations: a prefix of the unsynced ones, length drawn
  from rng (0 .. all), applied in order;
- each surviving file, in inode order: a prefix of its unsynced changes,
  and when that prefix stops short of a write, a torn piece of that
  write - its bytes up to a sector boundary (fake_fs_set_sector,
  default 512) drawn from rng, possibly none;
- files with no durable name are gone, synced or not.
A crash with rng = 0 keeps nothing unsynced (the strictest outcome).
Every draw comes from the given prng (libs/standard/distributed/prng.w)
in a fixed order, so the same seed on the same state yields the same
outcome on every target. Real disks may also reorder unsynced writes;
the prefix model does not, so it finds ordering bugs only up to that.

Faults (all deterministic, from the fs's own seeded prng):
- fake_fs_set_faults: per-mille rates of short transfers, EINTR, EAGAIN,
  ENOSPC and EIO on the operations in a mask (1 << FAKE_FS_OP_*); one
  roll per operation (plus one for a short length), in call order.
- fake_fs_fail_nth: the nth following operation of a kind (or of any
  kind) fails with an errno and has no effect.
- fake_fs_set_capacity: a byte budget for all file contents; a write
  that would exceed it is cut short, and one that cannot move a byte
  fails with ENOSPC.
A failed operation transfers nothing and changes nothing (EIO on sync
excepted, above). Delayed completion is not modelled: every call
completes before it returns.

Paths are compared as strings: use one spelling per file ("dir/f", no
"./", "//" or trailing '/'). "." and "/" always exist. Descriptors
start at FAKE_FS_FD_BASE and are never reused, so a descriptor from
before a crash fails with EBADF afterwards.

fake_fs_trace_hash folds every operation (kind, size argument, status,
transferred) into one number, and fake_fs_state_hash folds the visible
namespace and contents: equal seeds and scripts give equal hashes.
*/
import lib.lib
import lib.assert
import lib.io
import lib.mem
import lib.container
import lib.file_ops
import libs.standard.distributed.prng


const int FAKE_FS_OP_ANY = 0
const int FAKE_FS_OP_OPEN = 1
const int FAKE_FS_OP_CLOSE = 2
const int FAKE_FS_OP_READ = 3
const int FAKE_FS_OP_WRITE = 4
const int FAKE_FS_OP_SYNC = 5       # sync and datasync on a file
const int FAKE_FS_OP_RENAME = 6
const int FAKE_FS_OP_UNLINK = 7
const int FAKE_FS_OP_MKDIR = 8
const int FAKE_FS_OP_SYNC_DIR = 9   # sync_dir, and sync on a directory fd
const int FAKE_FS_OP_SEEK = 11
const int FAKE_FS_OP_TRUNCATE = 12
const int FAKE_FS_ZERO = -2

const int FAKE_FS_OP_CRASH = 10     # trace only

const int FAKE_FS_FD_BASE = 1000

const int FAKE_FS_ENOENT = 2
const int FAKE_FS_EIO = 5
const int FAKE_FS_EBADF = 9
const int FAKE_FS_EAGAIN = 11
const int FAKE_FS_EEXIST = 17
const int FAKE_FS_EISDIR = 21
const int FAKE_FS_EINVAL = 22
const int FAKE_FS_ENOSPC = 28
const int FAKE_FS_EINTR = 4

# Pseudo-errno for a short transfer chosen by fake_fs_fault.
const int FAKE_FS_SHORT = -1


struct fake_fs_blob:
	char* data
	int size
	int cap


# One unsynced data change.
struct fake_fs_change:
	int offset
	int length
	char* data          # owned copy of the written bytes; 0 for a truncation
	int truncate        # 1: set the size to offset


struct fake_fs_inode:
	int id
	int is_dir
	fake_fs_blob* live
	fake_fs_blob* durable
	list[fake_fs_change*] pending


struct fake_fs_name:
	char* path          # owned
	int inode


# One unsynced directory operation.
struct fake_fs_meta:
	int kind            # FAKE_FS_OP_OPEN (create) / MKDIR / RENAME / UNLINK
	char* path          # owned
	char* path2         # rename target, owned; 0 otherwise
	char* dir           # parent of path, owned
	char* dir2          # parent of path2, owned; 0 otherwise
	int inode


struct fake_fs_fd:
	int inode           # -1 once closed
	int offset
	int flags


struct fake_fs_rule:
	int kind
	int countdown
	int err


struct fake_fs:
	file_ops* ops
	prng* rng                         # fault decisions
	list[fake_fs_inode*] inodes       # by id; 0 once dropped
	list[fake_fs_name*] names         # volatile namespace
	list[fake_fs_name*] durable_names
	list[fake_fs_meta*] meta          # unsynced directory operations
	list[fake_fs_fd*] fds             # by fd - FAKE_FS_FD_BASE
	list[fake_fs_rule*] rules
	int sector
	int capacity                      # bytes, 0 = unlimited
	int used                          # sum of volatile file sizes
	int fault_mask
	int short_pm
	int eintr_pm
	int eagain_pm
	int enospc_pm
	int eio_pm
	int op_count
	int trace
	int crashes


/* Small helpers. */

int fake_fs_mix(int h, int v):
	return (h * 31 + v) & prng_mask31()


char* fake_fs_strdup(char* s):
	return mem_dup(s, strlen(s))


int fake_fs_streq(char* a, char* b):
	return strcmp(a, b) == 0


# 1 when path lies strictly under dir ("dir/...").
int fake_fs_under(char* path, char* dir):
	int n = strlen(dir)
	return mem_starts_with(path, strlen(path), 0, dir) && (path[n] == '/')


fake_fs_blob* fake_fs_blob_new():
	return new fake_fs_blob(0, 0, 0)


void fake_fs_blob_free(fake_fs_blob* b):
	if (cast(int, b.data) != 0): free(b.data)
	free(b)


void fake_fs_blob_reserve(fake_fs_blob* b, int n):
	if (n <= b.cap): return
	int cap = b.cap * 2
	if (cap < 64): cap = 64
	while (cap < n): cap = cap * 2
	char* grown = cast(char*, malloc(cap))
	if (b.size > 0): mem_copy[char](grown, b.data, b.size)
	if (cast(int, b.data) != 0): free(b.data)
	b.data = grown
	b.cap = cap


# Sets the size, zero-filling any extension.
void fake_fs_blob_resize(fake_fs_blob* b, int n):
	fake_fs_blob_reserve(b, n)
	if (n > b.size): mem_fill[char](&b.data[b.size], 0, n - b.size)
	b.size = n


void fake_fs_blob_write(fake_fs_blob* b, int offset, char* src, int length):
	if (offset + length > b.size): fake_fs_blob_resize(b, offset + length)
	mem_copy[char](&b.data[offset], src, length)


void fake_fs_blob_copy(fake_fs_blob* dst, fake_fs_blob* src):
	fake_fs_blob_resize(dst, 0)
	fake_fs_blob_write(dst, 0, src.data, src.size)


void fake_fs_apply_change(fake_fs_blob* b, fake_fs_change* c, int length):
	if (c.truncate): fake_fs_blob_resize(b, c.offset)
	else: fake_fs_blob_write(b, c.offset, c.data, length)


void fake_fs_change_free(fake_fs_change* c):
	if (cast(int, c.data) != 0): free(c.data)
	free(c)


void fake_fs_drop_pending(fake_fs_inode* node):
	for i in range(node.pending.length): fake_fs_change_free(node.pending[i])
	node.pending.clear()


/* Namespace. */

int fake_fs_find(list[fake_fs_name*] names, char* path):
	for i in range(names.length):
		if (fake_fs_streq(names[i].path, path)): return i
	return -1


void fake_fs_bind(list[fake_fs_name*] names, char* path, int inode):
	int i = fake_fs_find(names, path)
	if (i >= 0):
		names[i].inode = inode
		return
	names.push(new fake_fs_name(fake_fs_strdup(path), inode))


void fake_fs_unbind(list[fake_fs_name*] names, char* path):
	int i = fake_fs_find(names, path)
	if (i < 0): return
	free(names[i].path)
	free(names[i])
	list_remove_at[fake_fs_name*](names, i)


void fake_fs_names_clear(list[fake_fs_name*] names):
	for i in range(names.length):
		free(names[i].path)
		free(names[i])
	names.clear()


# Applies one directory operation to a namespace view. Renaming a
# directory carries every name under it along.
void fake_fs_apply_meta(list[fake_fs_name*] names, fake_fs_meta* m):
	if ((m.kind == FAKE_FS_OP_OPEN) || (m.kind == FAKE_FS_OP_MKDIR)):
		fake_fs_bind(names, m.path, m.inode)
	else if (m.kind == FAKE_FS_OP_UNLINK):
		fake_fs_unbind(names, m.path)
	else if (m.kind == FAKE_FS_OP_RENAME):
		int i = fake_fs_find(names, m.path)
		if (i < 0): return
		fake_fs_unbind(names, m.path2)
		i = fake_fs_find(names, m.path)
		free(names[i].path)
		names[i].path = fake_fs_strdup(m.path2)
		int n = strlen(m.path)
		int n2 = strlen(m.path2)
		for j in range(names.length):
			char* p = names[j].path
			if (fake_fs_under(p, m.path)):
				int rest = strlen(p) - n
				char* moved = cast(char*, malloc(n2 + rest + 1))
				mem_copy[char](moved, m.path2, n2)
				mem_copy[char](&moved[n2], &p[n], rest)
				moved[n2 + rest] = 0
				free(p)
				names[j].path = moved


void fake_fs_meta_free(fake_fs_meta* m):
	free(m.path)
	free(m.dir)
	if (cast(int, m.path2) != 0): free(m.path2)
	if (cast(int, m.dir2) != 0): free(m.dir2)
	free(m)


# Records a directory operation and applies it to the volatile view.
void fake_fs_log_meta(fake_fs* fs, int kind, char* path, char* path2, int inode):
	fake_fs_meta* m = new fake_fs_meta()
	m.kind = kind
	m.path = fake_fs_strdup(path)
	m.dir = file_ops_parent(path)
	m.path2 = 0
	m.dir2 = 0
	if (cast(int, path2) != 0):
		m.path2 = fake_fs_strdup(path2)
		m.dir2 = file_ops_parent(path2)
	m.inode = inode
	fake_fs_apply_meta(fs.names, m)
	fs.meta.push(m)


# Commits the first count pending directory operations to the durable view.
void fake_fs_commit_meta(fake_fs* fs, int count):
	for i in range(count):
		fake_fs_apply_meta(fs.durable_names, fs.meta[i])
		fake_fs_meta_free(fs.meta[i])
	for i in range(count): list_remove_at[fake_fs_meta*](fs.meta, 0)


int fake_fs_is_root(char* path):
	return fake_fs_streq(path, c".") || fake_fs_streq(path, c"/")


# Same directory: equal strings, or both spellings of the root.
int fake_fs_same_dir(char* a, char* b):
	if (fake_fs_streq(a, b)): return 1
	return fake_fs_is_root(a) && fake_fs_is_root(b)


fake_fs_inode* fake_fs_inode_at(fake_fs* fs, int id):
	return fs.inodes[id]


# The inode a volatile path names, or 0. "." and "/" are inode 0.
fake_fs_inode* fake_fs_lookup(fake_fs* fs, char* path):
	if (fake_fs_is_root(path)): return fake_fs_inode_at(fs, 0)
	int i = fake_fs_find(fs.names, path)
	if (i < 0): return 0
	return fake_fs_inode_at(fs, fs.names[i].inode)


int fake_fs_dir_exists(fake_fs* fs, char* dir):
	fake_fs_inode* node = fake_fs_lookup(fs, dir)
	return (cast(int, node) != 0) && node.is_dir


fake_fs_inode* fake_fs_inode_new(fake_fs* fs, int is_dir):
	fake_fs_inode* node = new fake_fs_inode()
	node.id = fs.inodes.length
	node.is_dir = is_dir
	node.live = fake_fs_blob_new()
	node.durable = fake_fs_blob_new()
	node.pending = new list[fake_fs_change*]
	fs.inodes.push(node)
	return node


void fake_fs_inode_free(fake_fs_inode* node):
	fake_fs_drop_pending(node)
	list_free[fake_fs_change*](node.pending)
	fake_fs_blob_free(node.live)
	fake_fs_blob_free(node.durable)
	free(node)


/* Results, trace and faults. */

int fake_fs_record(fake_fs* fs, int kind, int arg, io_result* r, int transferred, int status, int err):
	io_result_set(r, transferred, status, err)
	fs.op_count = fs.op_count + 1
	fs.trace = fake_fs_mix(fs.trace, kind)
	fs.trace = fake_fs_mix(fs.trace, arg)
	fs.trace = fake_fs_mix(fs.trace, status)
	fs.trace = fake_fs_mix(fs.trace, transferred)
	return status


# Records one operation's outcome: err 0 is IO_OK, else its category.
int fake_fs_finish(fake_fs* fs, int kind, int arg, io_result* r, int transferred, int err):
	int status = IO_OK
	if (err != 0): status = io_status_from_errno(err)
	return fake_fs_record(fs, kind, arg, r, transferred, status, err)


# The fault for this operation: an errno, FAKE_FS_SHORT, or 0 for none.
# Armed fail-on-nth rules count first, then one rate roll when the kind
# is in the fault mask.
int fake_fs_fault(fake_fs* fs, int kind):
	int i = 0
	while (i < fs.rules.length):
		fake_fs_rule* rule = fs.rules[i]
		if ((rule.kind == FAKE_FS_OP_ANY) || (rule.kind == kind)):
			rule.countdown = rule.countdown - 1
			if (rule.countdown <= 0):
				int err = rule.err
				free(rule)
				list_remove_at[fake_fs_rule*](fs.rules, i)
				return err
		i = i + 1
	if ((fs.fault_mask & (1 << kind)) == 0): return 0
	int roll = prng_range(fs.rng, 1000)
	int edge = fs.eintr_pm
	if (roll < edge): return FAKE_FS_EINTR
	edge = edge + fs.eagain_pm
	if (roll < edge): return FAKE_FS_EAGAIN
	edge = edge + fs.enospc_pm
	if (roll < edge): return FAKE_FS_ENOSPC
	edge = edge + fs.eio_pm
	if (roll < edge): return FAKE_FS_EIO
	edge = edge + fs.short_pm
	if (roll < edge): return FAKE_FS_SHORT
	return 0


# Transfer size after a possible short fault: 1 .. n - 1 when n > 1.
int fake_fs_short(fake_fs* fs, int n):
	if (n <= 1): return n
	return prng_between(fs.rng, 1, n - 1)


fake_fs_fd* fake_fs_fd_at(fake_fs* fs, int fd):
	int i = fd - FAKE_FS_FD_BASE
	if ((i < 0) || (i >= fs.fds.length)): return 0
	fake_fs_fd* f = fs.fds[i]
	if (f.inode < 0): return 0
	return f


int fake_fs_writable(int flags):
	int access = flags & 3
	return (access == FILE_OPS_WRITE) || (access == FILE_OPS_READ_WRITE)


int fake_fs_readable(int flags):
	int access = flags & 3
	return (access == FILE_OPS_READ) || (access == FILE_OPS_READ_WRITE)


# Truncates or writes the volatile copy and logs the change; keeps used.
void fake_fs_change_live(fake_fs* fs, fake_fs_inode* node, int offset, char* src, int length, int truncate):
	int before = node.live.size
	fake_fs_change* c = new fake_fs_change(offset, length, 0, truncate)
	if (truncate == 0): c.data = mem_dup(src, length)
	fake_fs_apply_change(node.live, c, length)
	node.pending.push(c)
	fs.used = fs.used + node.live.size - before


/* The file_ops implementation. */

int fake_fs_sync_dir_path(fake_fs* fs, char* dir, io_result* r):
	int err = fake_fs_fault(fs, FAKE_FS_OP_SYNC_DIR)
	if (err == FAKE_FS_SHORT): err = 0
	if ((err == 0) && (fake_fs_dir_exists(fs, dir) == 0)): err = FAKE_FS_ENOENT
	if (err == 0):
		int last = -1
		for i in range(fs.meta.length):
			fake_fs_meta* m = fs.meta[i]
			if (fake_fs_same_dir(m.dir, dir)): last = i
			if ((cast(int, m.dir2) != 0) && fake_fs_same_dir(m.dir2, dir)): last = i
		fake_fs_commit_meta(fs, last + 1)
	return fake_fs_finish(fs, FAKE_FS_OP_SYNC_DIR, 0, r, 0, err)


int fake_fs_op_sync_dir(void* self, char* path, io_result* r):
	return fake_fs_sync_dir_path(cast(fake_fs*, self), path, r)


int fake_fs_op_open(void* self, char* path, int flags, int mode, int* fd_out, io_result* r):
	fake_fs* fs = cast(fake_fs*, self)
	fd_out[0] = -1
	int err = fake_fs_fault(fs, FAKE_FS_OP_OPEN)
	if (err == FAKE_FS_SHORT): err = 0
	if (err != 0): return fake_fs_finish(fs, FAKE_FS_OP_OPEN, flags, r, 0, err)
	fake_fs_inode* node = fake_fs_lookup(fs, path)
	if (cast(int, node) != 0):
		if ((flags & FILE_OPS_CREATE) && (flags & FILE_OPS_EXCLUSIVE)):
			return fake_fs_finish(fs, FAKE_FS_OP_OPEN, flags, r, 0, FAKE_FS_EEXIST)
		if (node.is_dir && fake_fs_writable(flags)):
			return fake_fs_finish(fs, FAKE_FS_OP_OPEN, flags, r, 0, FAKE_FS_EISDIR)
		if ((flags & FILE_OPS_TRUNCATE) && fake_fs_writable(flags) && (node.live.size > 0)):
			fake_fs_change_live(fs, node, 0, 0, 0, 1)
	else:
		if ((flags & FILE_OPS_CREATE) == 0):
			return fake_fs_finish(fs, FAKE_FS_OP_OPEN, flags, r, 0, FAKE_FS_ENOENT)
		char* dir = file_ops_parent(path)
		int dir_ok = fake_fs_dir_exists(fs, dir)
		free(dir)
		if (dir_ok == 0): return fake_fs_finish(fs, FAKE_FS_OP_OPEN, flags, r, 0, FAKE_FS_ENOENT)
		node = fake_fs_inode_new(fs, 0)
		fake_fs_log_meta(fs, FAKE_FS_OP_OPEN, path, 0, node.id)
	fs.fds.push(new fake_fs_fd(node.id, 0, flags))
	fd_out[0] = FAKE_FS_FD_BASE + fs.fds.length - 1
	return fake_fs_finish(fs, FAKE_FS_OP_OPEN, flags, r, 0, 0)


int fake_fs_op_close(void* self, int fd, io_result* r):
	fake_fs* fs = cast(fake_fs*, self)
	fake_fs_fd* f = fake_fs_fd_at(fs, fd)
	if (cast(int, f) == 0): return fake_fs_finish(fs, FAKE_FS_OP_CLOSE, 0, r, 0, FAKE_FS_EBADF)
	# Released whatever the injected status, as on Linux.
	f.inode = -1
	int err = fake_fs_fault(fs, FAKE_FS_OP_CLOSE)
	if (err == FAKE_FS_SHORT): err = 0
	return fake_fs_finish(fs, FAKE_FS_OP_CLOSE, 0, r, 0, err)


int fake_fs_op_read(void* self, int fd, char* buffer, int length, io_result* r):
	fake_fs* fs = cast(fake_fs*, self)
	fake_fs_fd* f = fake_fs_fd_at(fs, fd)
	if ((cast(int, f) == 0) || (fake_fs_readable(f.flags) == 0)):
		return fake_fs_finish(fs, FAKE_FS_OP_READ, length, r, 0, FAKE_FS_EBADF)
	fake_fs_inode* node = fake_fs_inode_at(fs, f.inode)
	if (node.is_dir): return fake_fs_finish(fs, FAKE_FS_OP_READ, length, r, 0, FAKE_FS_EISDIR)
	if (length <= 0): return fake_fs_finish(fs, FAKE_FS_OP_READ, length, r, 0, 0)
	int err = fake_fs_fault(fs, FAKE_FS_OP_READ)
	int n = length
	if (err == FAKE_FS_ZERO): return fake_fs_finish(fs, FAKE_FS_OP_READ, length, r, 0, 0)
	if (err == FAKE_FS_SHORT):
		n = fake_fs_short(fs, length)
		err = 0
	if (err != 0): return fake_fs_finish(fs, FAKE_FS_OP_READ, length, r, 0, err)
	int left = node.live.size - f.offset
	if (left <= 0): return fake_fs_record(fs, FAKE_FS_OP_READ, length, r, 0, IO_EOF, 0)
	if (n > left): n = left
	mem_copy[char](buffer, &node.live.data[f.offset], n)
	f.offset = f.offset + n
	return fake_fs_finish(fs, FAKE_FS_OP_READ, length, r, n, 0)


int fake_fs_op_write(void* self, int fd, char* buffer, int length, io_result* r):
	fake_fs* fs = cast(fake_fs*, self)
	fake_fs_fd* f = fake_fs_fd_at(fs, fd)
	if ((cast(int, f) == 0) || (fake_fs_writable(f.flags) == 0)):
		return fake_fs_finish(fs, FAKE_FS_OP_WRITE, length, r, 0, FAKE_FS_EBADF)
	if (length <= 0): return fake_fs_finish(fs, FAKE_FS_OP_WRITE, length, r, 0, 0)
	fake_fs_inode* node = fake_fs_inode_at(fs, f.inode)
	int err = fake_fs_fault(fs, FAKE_FS_OP_WRITE)
	int n = length
	if (err == FAKE_FS_ZERO): return fake_fs_finish(fs, FAKE_FS_OP_WRITE, length, r, 0, 0)
	if (err == FAKE_FS_SHORT):
		n = fake_fs_short(fs, length)
		err = 0
	if (err != 0): return fake_fs_finish(fs, FAKE_FS_OP_WRITE, length, r, 0, err)
	if (f.flags & FILE_OPS_APPEND): f.offset = node.live.size
	if (fs.capacity > 0):
		int max_end = node.live.size + (fs.capacity - fs.used)
		if (f.offset + n > max_end): n = max_end - f.offset
		if (n <= 0): return fake_fs_finish(fs, FAKE_FS_OP_WRITE, length, r, 0, FAKE_FS_ENOSPC)
	fake_fs_change_live(fs, node, f.offset, buffer, n, 0)
	f.offset = f.offset + n
	return fake_fs_finish(fs, FAKE_FS_OP_WRITE, length, r, n, 0)


# Volatile path of a directory inode, or 0.
char* fake_fs_path_of(fake_fs* fs, int inode):
	if (inode == 0): return c"."
	for i in range(fs.names.length):
		if (fs.names[i].inode == inode): return fs.names[i].path
	return 0


int fake_fs_op_sync(void* self, int fd, io_result* r):
	fake_fs* fs = cast(fake_fs*, self)
	fake_fs_fd* f = fake_fs_fd_at(fs, fd)
	if (cast(int, f) == 0): return fake_fs_finish(fs, FAKE_FS_OP_SYNC, 0, r, 0, FAKE_FS_EBADF)
	fake_fs_inode* node = fake_fs_inode_at(fs, f.inode)
	if (node.is_dir):
		char* path = fake_fs_path_of(fs, node.id)
		if (cast(int, path) == 0): return fake_fs_finish(fs, FAKE_FS_OP_SYNC_DIR, 0, r, 0, FAKE_FS_ENOENT)
		return fake_fs_sync_dir_path(fs, path, r)
	int err = fake_fs_fault(fs, FAKE_FS_OP_SYNC)
	if (err == FAKE_FS_SHORT): err = 0
	if (err == FAKE_FS_EIO):
		# Writeback failed: the pages count as clean, the data is gone.
		fake_fs_drop_pending(node)
	else if (err == 0):
		for i in range(node.pending.length):
			fake_fs_change* c = node.pending[i]
			fake_fs_apply_change(node.durable, c, c.length)
		fake_fs_drop_pending(node)
	return fake_fs_finish(fs, FAKE_FS_OP_SYNC, 0, r, 0, err)


int fake_fs_op_rename(void* self, char* from, char* to, io_result* r):
	fake_fs* fs = cast(fake_fs*, self)
	int err = fake_fs_fault(fs, FAKE_FS_OP_RENAME)
	if (err == FAKE_FS_SHORT): err = 0
	if (err != 0): return fake_fs_finish(fs, FAKE_FS_OP_RENAME, 0, r, 0, err)
	if (fake_fs_is_root(from) || fake_fs_is_root(to)):
		return fake_fs_finish(fs, FAKE_FS_OP_RENAME, 0, r, 0, FAKE_FS_EINVAL)
	fake_fs_inode* node = fake_fs_lookup(fs, from)
	if (cast(int, node) == 0): return fake_fs_finish(fs, FAKE_FS_OP_RENAME, 0, r, 0, FAKE_FS_ENOENT)
	char* dir = file_ops_parent(to)
	int dir_ok = fake_fs_dir_exists(fs, dir)
	free(dir)
	if (dir_ok == 0): return fake_fs_finish(fs, FAKE_FS_OP_RENAME, 0, r, 0, FAKE_FS_ENOENT)
	fake_fs_inode* target = fake_fs_lookup(fs, to)
	if ((cast(int, target) != 0) && target.is_dir):
		return fake_fs_finish(fs, FAKE_FS_OP_RENAME, 0, r, 0, FAKE_FS_EISDIR)
	if (fake_fs_under(to, from)): return fake_fs_finish(fs, FAKE_FS_OP_RENAME, 0, r, 0, FAKE_FS_EINVAL)
	if (fake_fs_streq(from, to) == 0): fake_fs_log_meta(fs, FAKE_FS_OP_RENAME, from, to, node.id)
	return fake_fs_finish(fs, FAKE_FS_OP_RENAME, 0, r, 0, 0)


int fake_fs_op_unlink(void* self, char* path, io_result* r):
	fake_fs* fs = cast(fake_fs*, self)
	int err = fake_fs_fault(fs, FAKE_FS_OP_UNLINK)
	if (err == FAKE_FS_SHORT): err = 0
	if (err != 0): return fake_fs_finish(fs, FAKE_FS_OP_UNLINK, 0, r, 0, err)
	fake_fs_inode* node = fake_fs_lookup(fs, path)
	if (cast(int, node) == 0): return fake_fs_finish(fs, FAKE_FS_OP_UNLINK, 0, r, 0, FAKE_FS_ENOENT)
	if (node.is_dir): return fake_fs_finish(fs, FAKE_FS_OP_UNLINK, 0, r, 0, FAKE_FS_EISDIR)
	fake_fs_log_meta(fs, FAKE_FS_OP_UNLINK, path, 0, node.id)
	return fake_fs_finish(fs, FAKE_FS_OP_UNLINK, 0, r, 0, 0)


int fake_fs_op_mkdir(void* self, char* path, int mode, io_result* r):
	fake_fs* fs = cast(fake_fs*, self)
	int err = fake_fs_fault(fs, FAKE_FS_OP_MKDIR)
	if (err == FAKE_FS_SHORT): err = 0
	if (err != 0): return fake_fs_finish(fs, FAKE_FS_OP_MKDIR, 0, r, 0, err)
	if (cast(int, fake_fs_lookup(fs, path)) != 0):
		return fake_fs_finish(fs, FAKE_FS_OP_MKDIR, 0, r, 0, FAKE_FS_EEXIST)
	char* dir = file_ops_parent(path)
	int dir_ok = fake_fs_dir_exists(fs, dir)
	free(dir)
	if (dir_ok == 0): return fake_fs_finish(fs, FAKE_FS_OP_MKDIR, 0, r, 0, FAKE_FS_ENOENT)
	fake_fs_inode* node = fake_fs_inode_new(fs, 1)
	fake_fs_log_meta(fs, FAKE_FS_OP_MKDIR, path, 0, node.id)
	return fake_fs_finish(fs, FAKE_FS_OP_MKDIR, 0, r, 0, 0)


/* Lifecycle and configuration. */

# An empty filesystem whose fault decisions come from seed.
int fake_fs_op_seek(void* self, int fd, int offset, int whence, io_result* r):
	fake_fs* fs = cast(fake_fs*, self)
	fake_fs_fd* f = fake_fs_fd_at(fs, fd)
	if (cast(int, f) == 0): return fake_fs_finish(fs, FAKE_FS_OP_SEEK, offset, r, 0, FAKE_FS_EBADF)
	int err = fake_fs_fault(fs, FAKE_FS_OP_SEEK)
	if (err == FAKE_FS_SHORT): err = 0
	int pos = offset
	if (whence == 1): pos = f.offset + offset
	if (whence == 2): pos = fake_fs_inode_at(fs, f.inode).live.size + offset
	if (pos < 0 || whence < 0 || whence > 2): err = FAKE_FS_EINVAL
	if (err == 0): f.offset = pos
	return fake_fs_finish(fs, FAKE_FS_OP_SEEK, offset, r, pos, err)


int fake_fs_op_truncate(void* self, int fd, int length, io_result* r):
	fake_fs* fs = cast(fake_fs*, self)
	fake_fs_fd* f = fake_fs_fd_at(fs, fd)
	if (cast(int, f) == 0 || fake_fs_writable(f.flags) == 0): return fake_fs_finish(fs, FAKE_FS_OP_TRUNCATE, length, r, 0, FAKE_FS_EBADF)
	int err = fake_fs_fault(fs, FAKE_FS_OP_TRUNCATE)
	if (err == FAKE_FS_SHORT): err = 0
	if (length < 0): err = FAKE_FS_EINVAL
	fake_fs_inode* node = fake_fs_inode_at(fs, f.inode)
	if (fs.capacity > 0 && length - node.live.size > fs.capacity - fs.used): err = FAKE_FS_ENOSPC
	if (err == 0): fake_fs_change_live(fs, node, length, 0, 0, 1)
	return fake_fs_finish(fs, FAKE_FS_OP_TRUNCATE, length, r, 0, err)


fake_fs* fake_fs_new(int seed):
	fake_fs* fs = new fake_fs()
	fs.rng = prng_new(seed)
	fs.inodes = new list[fake_fs_inode*]
	fs.names = new list[fake_fs_name*]
	fs.durable_names = new list[fake_fs_name*]
	fs.meta = new list[fake_fs_meta*]
	fs.fds = new list[fake_fs_fd*]
	fs.rules = new list[fake_fs_rule*]
	fs.sector = 512
	fs.capacity = 0
	fs.used = 0
	fs.fault_mask = 0
	fs.short_pm = 0
	fs.eintr_pm = 0
	fs.eagain_pm = 0
	fs.enospc_pm = 0
	fs.eio_pm = 0
	fs.op_count = 0
	fs.trace = 0
	fs.crashes = 0
	fake_fs_inode_new(fs, 1)          # inode 0: the root, never named
	file_ops* ops = file_ops_new(cast(void*, fs))
	ops.open = fake_fs_op_open
	ops.close = fake_fs_op_close
	ops.read = fake_fs_op_read
	ops.write = fake_fs_op_write
	ops.sync = fake_fs_op_sync
	ops.datasync = fake_fs_op_sync
	ops.rename = fake_fs_op_rename
	ops.unlink = fake_fs_op_unlink
	ops.mkdir = fake_fs_op_mkdir
	ops.sync_dir = fake_fs_op_sync_dir
	ops.seek = fake_fs_op_seek
	ops.truncate = fake_fs_op_truncate
	fs.ops = ops
	return fs


# The file_ops table for this filesystem (owned by fs).
file_ops* fake_fs_ops(fake_fs* fs):
	return fs.ops


void fake_fs_free(fake_fs* fs):
	for i in range(fs.inodes.length):
		if (cast(int, fs.inodes[i]) != 0): fake_fs_inode_free(fs.inodes[i])
	list_free[fake_fs_inode*](fs.inodes)
	fake_fs_names_clear(fs.names)
	list_free[fake_fs_name*](fs.names)
	fake_fs_names_clear(fs.durable_names)
	list_free[fake_fs_name*](fs.durable_names)
	for i in range(fs.meta.length): fake_fs_meta_free(fs.meta[i])
	list_free[fake_fs_meta*](fs.meta)
	for i in range(fs.fds.length): free(fs.fds[i])
	list_free[fake_fs_fd*](fs.fds)
	for i in range(fs.rules.length): free(fs.rules[i])
	list_free[fake_fs_rule*](fs.rules)
	prng_free(fs.rng)
	free(fs.ops)
	free(fs)


# Per-mille fault rates for the operations in op_mask (bits
# 1 << FAKE_FS_OP_*); all zero turns rate faults off. Short transfers
# apply to read and write only.
void fake_fs_set_faults(fake_fs* fs, int op_mask, int short_pm, int eintr_pm, int eagain_pm, int enospc_pm, int eio_pm):
	int total = short_pm + eintr_pm + eagain_pm + enospc_pm + eio_pm
	asserts(c"fake_fs_set_faults: rates sum to at most 1000", total <= 1000)
	fs.fault_mask = op_mask
	fs.short_pm = short_pm
	fs.eintr_pm = eintr_pm
	fs.eagain_pm = eagain_pm
	fs.enospc_pm = enospc_pm
	fs.eio_pm = eio_pm


# The nth following operation of kind (FAKE_FS_OP_ANY: of any kind)
# fails with errno err and has no effect. Rules stack.
void fake_fs_fail_nth(fake_fs* fs, int kind, int nth, int err):
	asserts(c"fake_fs_fail_nth: nth >= 1", nth >= 1)
	fs.rules.push(new fake_fs_rule(kind, nth, err))


# Total bytes all files may hold (0: unlimited).
void fake_fs_set_capacity(fake_fs* fs, int bytes):
	fs.capacity = bytes


# Torn-write granularity in bytes.
void fake_fs_set_sector(fake_fs* fs, int bytes):
	asserts(c"fake_fs_set_sector: sector >= 1", bytes >= 1)
	fs.sector = bytes


/* Crash. */

int fake_fs_state_hash(fake_fs* fs);

int fake_fs_referenced(list[fake_fs_name*] names, int inode):
	for i in range(names.length):
		if (names[i].inode == inode): return 1
	return 0


# Simulated power loss (header): keeps a seeded permitted subset of the
# unsynced state, drops the rest, invalidates every descriptor.
void fake_fs_crash(fake_fs* fs, prng* rng):
	for i in range(fs.fds.length): fs.fds[i].inode = -1
	int keep = 0
	if (cast(int, rng) != 0): keep = prng_range(rng, fs.meta.length + 1)
	fake_fs_commit_meta(fs, keep)
	for i in range(fs.meta.length): fake_fs_meta_free(fs.meta[i])
	fs.meta.clear()
	fake_fs_names_clear(fs.names)
	for i in range(fs.durable_names.length):
		fs.names.push(new fake_fs_name(fake_fs_strdup(fs.durable_names[i].path), fs.durable_names[i].inode))
	fs.used = 0
	for id in range(fs.inodes.length):
		fake_fs_inode* node = fs.inodes[id]
		if (cast(int, node) == 0): continue
		if ((id != 0) && (fake_fs_referenced(fs.durable_names, id) == 0)):
			fake_fs_inode_free(node)
			fs.inodes[id] = 0
			continue
		int n = node.pending.length
		int k = 0
		if (cast(int, rng) != 0): k = prng_range(rng, n + 1)
		for i in range(k):
			fake_fs_change* c = node.pending[i]
			fake_fs_apply_change(node.durable, c, c.length)
		if ((k < n) && (cast(int, rng) != 0)):
			fake_fs_change* torn = node.pending[k]
			if (torn.truncate == 0):
				int end = torn.offset + torn.length
				int first = (torn.offset / fs.sector + 1) * fs.sector
				int cuts = 0
				if (first < end): cuts = (end - 1 - first) / fs.sector + 1
				int t = prng_range(rng, cuts + 1)
				if (t > 0):
					int cut = first + (t - 1) * fs.sector
					fake_fs_apply_change(node.durable, torn, cut - torn.offset)
		fake_fs_drop_pending(node)
		fake_fs_blob_copy(node.live, node.durable)
		fs.used = fs.used + node.live.size
	fs.crashes = fs.crashes + 1
	fs.trace = fake_fs_mix(fs.trace, FAKE_FS_OP_CRASH)
	fs.trace = fake_fs_mix(fs.trace, fake_fs_state_hash(fs))


/* Inspection (volatile view: what a reader would see now). */

int fake_fs_exists(fake_fs* fs, char* path):
	return cast(int, fake_fs_lookup(fs, path)) != 0


# Size of the file at path, or -1 when absent.
int fake_fs_file_size(fake_fs* fs, char* path):
	fake_fs_inode* node = fake_fs_lookup(fs, path)
	if (cast(int, node) == 0): return -1
	return node.live.size


# Borrowed pointer to the contents (valid until the next operation), or
# 0 when absent.
char* fake_fs_file_data(fake_fs* fs, char* path):
	fake_fs_inode* node = fake_fs_lookup(fs, path)
	if (cast(int, node) == 0): return 0
	return node.live.data


# 1 when the file at path holds exactly the length bytes at want.
int fake_fs_file_equals(fake_fs* fs, char* path, char* want, int length):
	fake_fs_inode* node = fake_fs_lookup(fs, path)
	if (cast(int, node) == 0): return 0
	if (node.live.size != length): return 0
	return mem_eq[char](node.live.data, want, length)


# Unsynced data changes of the file at path (0 when absent).
int fake_fs_pending_changes(fake_fs* fs, char* path):
	fake_fs_inode* node = fake_fs_lookup(fs, path)
	if (cast(int, node) == 0): return 0
	return node.pending.length


# Unsynced directory operations.
int fake_fs_pending_meta(fake_fs* fs):
	return fs.meta.length


int fake_fs_trace_hash(fake_fs* fs):
	return fs.trace


int fake_fs_op_count(fake_fs* fs):
	return fs.op_count


# The visible namespace and file contents folded into one number.
int fake_fs_state_hash(fake_fs* fs):
	int h = 0
	for i in range(fs.names.length):
		fake_fs_name* name = fs.names[i]
		char* p = name.path
		for j in range(strlen(p)): h = fake_fs_mix(h, p[j])
		fake_fs_inode* node = fake_fs_inode_at(fs, name.inode)
		h = fake_fs_mix(h, node.is_dir)
		h = fake_fs_mix(h, node.live.size)
		for j in range(node.live.size): h = fake_fs_mix(h, node.live.data[j] & 255)
	return h
