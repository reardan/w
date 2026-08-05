/*
Linux inotify(7) file-watch wrappers and event-record parsing: the
wbuildd stage-1 prerequisite from issue #231
(docs/projects/wbuildd.md par. 2.3).

The syscall shims (sys_inotify_init1 / sys_inotify_add_watch /
sys_inotify_rm_watch) live per-architecture in
lib/__arch__/syscalls.w; only the syscall NUMBER differs between the
Linux targets (x86 332/292/293, x64 294/254/255, arm64 26/27/28), so
the constants and the record parser live once here. Darwin / win64 /
wasm have no inotify: their shims return a negative errno-style
failure without entering the kernel, the lib/stat.w statx convention.

read() on an inotify fd fills the buffer with packed variable-length
records (uapi/linux/inotify.h), identical layout on every Linux ABI:

	bytes 0..3    wd      watch descriptor the event belongs to
	bytes 4..7    mask    event bits (IN_* below)
	bytes 8..11   cookie  links IN_MOVED_FROM/IN_MOVED_TO pairs
	bytes 12..15  len     size of the name field, INCLUDING NUL padding
	bytes 16..    name    len bytes; NUL-terminated when len > 0

len is 0 for events about the watched object itself (IN_DELETE_SELF,
IN_IGNORED, ...) and nonzero with the child's basename for events
inside a watched directory. A record is 16 + len bytes; the next
record starts immediately after. inotify_event_parse walks that
layout; buffers are plain char*, so the pointer arithmetic below is
byte-offset arithmetic by construction (the `T* + int` raw-offset
rule is exactly what packed records want).

Fields load through load_int32, which sign-extends on 64-bit targets.
That cannot bite in practice: every mask bit the kernel DELIVERS fits
in 31 bits (IN_ONESHOT, bit 31, is a watch-request flag only and is
deliberately not defined here), len is bounded by NAME_MAX padding,
and cookies only ever need equality comparison.

The read buffer handed to read() must have room for at least one
whole record or the kernel fails the read with -EINVAL;
INOTIFY_BUF_SIZE() is a comfortable default that batches many events
per syscall.
*/
import lib.lib


/* Event mask bits (uapi/linux/inotify.h). Usable both as the
inotify_add_watch mask and for testing a delivered event's mask. */

int IN_ACCESS():
	return 1


int IN_MODIFY():
	return 2


int IN_ATTRIB():
	return 4


int IN_CLOSE_WRITE():
	return 8


int IN_CLOSE_NOWRITE():
	return 16


int IN_OPEN():
	return 32


int IN_MOVED_FROM():
	return 64


int IN_MOVED_TO():
	return 128


int IN_CREATE():
	return 256


int IN_DELETE():
	return 512


int IN_DELETE_SELF():
	return 1024


int IN_MOVE_SELF():
	return 2048


# Every event above (0xfff): the usual "watch everything" mask.
int IN_ALL_EVENTS():
	return 4095


/* Bits the kernel adds to delivered events (never valid in an
inotify_add_watch mask). */

# The watched filesystem was unmounted.
int IN_UNMOUNT():
	return 8192


# The kernel event queue overflowed and events were dropped; wd is -1.
int IN_Q_OVERFLOW():
	return 16384


# The watch was removed (explicit inotify_rm_watch, or the watched
# object disappeared). Always the last event a wd delivers.
int IN_IGNORED():
	return 32768


# Set alongside the event bit when the subject is a directory
# (0x40000000).
int IN_ISDIR():
	return 1073741824


/* inotify_add_watch request-only flags. */

# Only watch path if it is a directory (0x1000000).
int IN_ONLYDIR():
	return 16777216


# Do not dereference path if it is a symlink (0x2000000).
int IN_DONT_FOLLOW():
	return 33554432


# Add (OR) these events to an existing watch instead of replacing its
# mask (0x20000000).
int IN_MASK_ADD():
	return 536870912


/* sys_inotify_init1 flags: the Linux O_NONBLOCK / O_CLOEXEC values
(inotify is Linux-only, so no socket_abi-style per-target indirection
is needed). */

int IN_NONBLOCK():
	return 2048


int IN_CLOEXEC():
	return 524288


# Fixed header size of one record; a record is this plus its len field.
int INOTIFY_EVENT_HEADER_SIZE():
	return 16


# Comfortable read() buffer size: at least one maximal record
# (16 + NAME_MAX + 1 = 272 bytes) with room to batch many events.
int INOTIFY_BUF_SIZE():
	return 4096


# One parsed event. name points INTO the read buffer (valid until the
# buffer is reused or freed) and is always NUL-terminated; it is the
# empty string for events without a name.
struct inotify_event:
	int wd
	int mask
	int cookie
	int name_length
	char* name


# Creates a blocking inotify instance. Returns the inotify fd, or a
# negative errno (close() it like any fd when done; that drops every
# watch too).
int inotify_init():
	return sys_inotify_init1(0)


# Creates a non-blocking inotify instance: read() with no queued
# events returns -EAGAIN instead of blocking. The fd also composes
# with lib/poll.w / lib/event_loop.w as one more readable fd.
int inotify_init_nonblocking():
	return sys_inotify_init1(IN_NONBLOCK())


# Watches path for the events in mask. Returns a watch descriptor
# (unique per inotify fd), or a negative errno. Watching an already
# watched path replaces its mask (or extends it with IN_MASK_ADD).
int inotify_add_watch(int fd, char* path, int mask):
	return sys_inotify_add_watch(fd, path, mask)


# Removes a watch; the wd delivers one final IN_IGNORED event.
int inotify_rm_watch(int fd, int wd):
	return sys_inotify_rm_watch(fd, wd)


# Byte size of the record starting at buf[offset] (header + name
# padding), assuming a well-formed record; use inotify_event_parse for
# bounds-checked walking.
int inotify_event_record_size(char* buf, int offset):
	return INOTIFY_EVENT_HEADER_SIZE() + load_int32(&buf[offset + 12])


# Parses the record starting at buf[offset] into *out and returns the
# offset of the next record. buf_end is the byte count a read()
# returned; iterate from offset 0 while the returned offset is below
# buf_end. Returns -1 when no whole record starts at offset (offset at
# or past buf_end, or a truncated/malformed record).
int inotify_event_parse(char* buf, int buf_end, int offset, inotify_event* out):
	if (offset < 0 || offset + INOTIFY_EVENT_HEADER_SIZE() > buf_end):
		return -1
	int name_field_length = load_int32(&buf[offset + 12])
	if (name_field_length < 0):
		return -1
	int next = offset + INOTIFY_EVENT_HEADER_SIZE() + name_field_length
	if (next > buf_end):
		return -1
	out.wd = load_int32(&buf[offset])
	out.mask = load_int32(&buf[offset + 4])
	out.cookie = load_int32(&buf[offset + 8])
	if (name_field_length == 0):
		out.name = c""
	else:
		# NUL-padded to name_field_length; strlen finds the real end.
		out.name = &buf[offset + INOTIFY_EVENT_HEADER_SIZE()]
	out.name_length = strlen(out.name)
	return next
