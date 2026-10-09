/*
Deterministic delayed I/O for lib.fake_fs (issue #514, W4).

Submission copies write bytes / directory paths and owns read buffers.
Each request has two events: execute the file_ops operation, then publish
its result after a separate completion delay. Until publication, result()
returns IO_WOULD_BLOCK, even if a sync has already made data durable.
This models both slow storage and a delayed notification, without sleeping
or threads. Short I/O and injected errors are returned unchanged; retries
are separate requests, so a test controls their timing too.

The queue borrows its filesystem and monotonic clock. Use a virtual clock
or sim_env_clock; advance that clock and call poll, or arm an event_loop
timer using next_delay. Poll executes due events in time order, breaking
ties by submission order, even when time advances past several events.
Explicit delays can come from a seeded prng. Wall time never participates.
Delays total at most 1e9 ms; poll gaps must be less than 2^31 ms, matching
the wrapping millisecond contract on x86. Do not move monotonic time back.

Requests are single attempts, not transactions or descriptor queues.
Overlapping requests execute in their scripted order (including requests
on the same fd). Wait for a write's completion before submitting the sync
that acknowledges it. Keep descriptors open until their requests finish.

Cancellation before execution prevents the operation. After execution it
sets cancelled but still waits for publication and reports the real result;
effects cannot be undone. A filesystem crash invalidates all unpublished
requests, including executed ones: result is IO_CANCELLED and crashed=1,
never a stale success. The underlying fake decides which effects survive.
Direct fake_fs_crash / sim_env_crash are detected on the next queue call.
Pump events up to a chosen crash point before crashing if they should run.

Count and byte limits include completed requests until release. Byte cost
counts the request and its owned buffer; the list's bounded pointer storage
is additional. Release refuses unfinished work. free is simulation teardown:
it discards all requests and invalidates handles without executing them.
Free the queue before its borrowed filesystem and clock. No callbacks or
caller-owned result/buffer pointers survive submission. All access is on
one simulation owner; this is not a thread-safe production executor.
*/
import lib.fake_fs
import lib.wclock
import lib.checked


const int FAKE_FS_ASYNC_QUEUED = 0
const int FAKE_FS_ASYNC_EXECUTED = 1
const int FAKE_FS_ASYNC_DONE = 2
const int FAKE_FS_ASYNC_MAX_DELAY = 1000000000


struct fake_fs_request:
	int kind
	int fd
	char* data                 # owned write copy, read buffer, or directory path
	int length
	int cost
	int execute_at
	int complete_at
	int state
	int cancelled
	int crashed
	io_result outcome          # private until result() reports completion


struct fake_fs_async:
	fake_fs* fs
	wclock* clock
	list[fake_fs_request*] requests
	int max_requests
	int max_bytes
	int bytes
	int crashes


fake_fs_async* fake_fs_async_new(fake_fs* fs, wclock* clock, int max_requests, int max_bytes):
	if (fs == 0 || clock == 0 || max_requests <= 0 || max_bytes < sizeof(fake_fs_request)): return 0
	fake_fs_async* q = new fake_fs_async()
	q.fs = fs
	q.clock = clock
	q.requests = new list[fake_fs_request*]
	q.max_requests = max_requests
	q.max_bytes = max_bytes
	q.crashes = fs.crashes
	return q


# Reconcile a crash even when the clock is failing. Published results
# remain historical results; only unpublished work is invalidated.
void fake_fs_async_observe_crash(fake_fs_async* q):
	if (q.crashes == q.fs.crashes): return
	q.crashes = q.fs.crashes
	for i in range(q.requests.length):
		fake_fs_request* r = q.requests[i]
		if (r.state != FAKE_FS_ASYNC_DONE):
			r.state = FAKE_FS_ASYNC_DONE
			r.crashed = 1
			io_result_set(&r.outcome, 0, IO_CANCELLED, 0)


# kind: FAKE_FS_OP_READ, WRITE, SYNC (also datasync in this model), or
# SYNC_DIR. bytes/length describe a write or an unterminated directory
# path; READ uses length with bytes=0; SYNC uses bytes=0, length=0.
# IO_OK admits work; IO_WOULD_BLOCK means the queue is full. out is always
# cleared on failure. Rejected submissions allocate nothing and do no I/O.
int fake_fs_async_submit(fake_fs_async* q, int kind, int fd, char* bytes, int length, int execute_delay, int completion_delay, fake_fs_request** out):
	out[0] = 0
	fake_fs_async_observe_crash(q)
	if (kind != FAKE_FS_OP_READ && kind != FAKE_FS_OP_WRITE && kind != FAKE_FS_OP_SYNC && kind != FAKE_FS_OP_SYNC_DIR): return IO_UNSUPPORTED
	if (length < 0 || execute_delay < 0 || completion_delay < 0): return IO_IO_ERROR
	if (execute_delay > FAKE_FS_ASYNC_MAX_DELAY || completion_delay > FAKE_FS_ASYNC_MAX_DELAY - execute_delay): return IO_IO_ERROR
	if (kind == FAKE_FS_OP_SYNC && length != 0): return IO_IO_ERROR
	if ((kind == FAKE_FS_OP_WRITE || kind == FAKE_FS_OP_SYNC_DIR) && length > 0 && bytes == 0): return IO_IO_ERROR
	int buffer_size = 0
	int cost = 0
	if (checked_add(length, 1, &buffer_size) == 0): return IO_NO_SPACE
	if (checked_add(sizeof(fake_fs_request), buffer_size, &cost) == 0): return IO_NO_SPACE
	if (cost > q.max_bytes): return IO_NO_SPACE
	if (q.requests.length >= q.max_requests || cost > q.max_bytes - q.bytes): return IO_WOULD_BLOCK
	if (kind == FAKE_FS_OP_SYNC_DIR):
		if (length == 0): return IO_IO_ERROR
		for i in range(length):
			if (bytes[i] == 0): return IO_IO_ERROR
	int now = 0
	int status = wclock_monotonic_ms(q.clock, &now)
	if (status != IO_OK): return status
	fake_fs_request* r = new fake_fs_request()
	r.kind = kind
	r.fd = fd
	r.length = length
	r.cost = cost
	r.data = cast(char*, malloc(buffer_size))
	if ((kind == FAKE_FS_OP_WRITE || kind == FAKE_FS_OP_SYNC_DIR) && length > 0): mem_copy(r.data, bytes, length)
	r.data[length] = 0
	r.execute_at = now + execute_delay
	r.complete_at = r.execute_at + completion_delay
	io_result_set(&r.outcome, 0, IO_WOULD_BLOCK, 0)
	q.requests.push(r)
	q.bytes = q.bytes + cost
	out[0] = r
	return IO_OK


# Returns the index of the earliest unprocessed event, or -1. Keeping
# completed requests in the list preserves submission order for ties.
int fake_fs_async_next(fake_fs_async* q, int now, int* delay):
	int best = -1
	int left = 0
	for i in range(q.requests.length):
		fake_fs_request* r = q.requests[i]
		if (r.state == FAKE_FS_ASYNC_DONE): continue
		int at = r.execute_at
		if (r.state == FAKE_FS_ASYNC_EXECUTED): at = r.complete_at
		int d = at - now
		if (best == -1 || d < left):
			best = i
			left = d
	delay[0] = left
	return best


# IO_OK with delay=-1 means idle. A due event returns delay=0. Clock
# failures are distinct from idle and never execute or publish requests.
int fake_fs_async_next_delay(fake_fs_async* q, int* delay):
	delay[0] = -1
	fake_fs_async_observe_crash(q)
	int now = 0
	int status = wclock_monotonic_ms(q.clock, &now)
	if (status != IO_OK): return status
	int left = 0
	if (fake_fs_async_next(q, now, &left) == -1): return IO_OK
	if (left < 0): left = 0
	delay[0] = left
	return IO_OK


# Runs all events due at the current monotonic time. One attempt per
# request preserves short transfers, EINTR, EAGAIN and injected failures.
int fake_fs_async_poll(fake_fs_async* q):
	fake_fs_async_observe_crash(q)
	int now = 0
	int status = wclock_monotonic_ms(q.clock, &now)
	if (status != IO_OK): return status
	while (1):
		int delay = 0
		int index = fake_fs_async_next(q, now, &delay)
		if (index == -1 || delay > 0): return IO_OK
		fake_fs_request* r = q.requests[index]
		if (r.state == FAKE_FS_ASYNC_EXECUTED):
			r.state = FAKE_FS_ASYNC_DONE
		else:
			file_ops* ops = fake_fs_ops(q.fs)
			if (r.kind == FAKE_FS_OP_WRITE): file_ops_write(ops, r.fd, r.data, r.length, &r.outcome)
			else if (r.kind == FAKE_FS_OP_READ): file_ops_read(ops, r.fd, r.data, r.length, &r.outcome)
			else if (r.kind == FAKE_FS_OP_SYNC): file_ops_sync(ops, r.fd, &r.outcome)
			else: file_ops_sync_dir(ops, r.data, &r.outcome)
			r.state = FAKE_FS_ASYNC_EXECUTED
	return IO_OK


# Handles must belong to q and remain live until release/free.
# The returned value says whether a result is available; the operation's
# status is in out.status (which may itself be IO_WOULD_BLOCK).
int fake_fs_async_result(fake_fs_async* q, fake_fs_request* r, io_result* out):
	fake_fs_async_observe_crash(q)
	if (r.state != FAKE_FS_ASYNC_DONE): return io_result_set(out, 0, IO_WOULD_BLOCK, 0)
	io_result_set(out, r.outcome.transferred, r.outcome.status, r.outcome.native_error)
	return IO_OK


# Does not pump time or run due work: the order of cancel/poll calls at
# the same timestamp is the scripted race. After execution, cancellation
# cannot erase effects or allow early release of the request.
void fake_fs_async_cancel(fake_fs_async* q, fake_fs_request* r):
	fake_fs_async_observe_crash(q)
	if (r.state == FAKE_FS_ASYNC_DONE): return
	r.cancelled = 1
	if (r.state == FAKE_FS_ASYNC_QUEUED):
		r.state = FAKE_FS_ASYNC_DONE
		io_result_set(&r.outcome, 0, IO_CANCELLED, 0)


int fake_fs_async_release(fake_fs_async* q, fake_fs_request* r):
	fake_fs_async_observe_crash(q)
	if (r.state != FAKE_FS_ASYNC_DONE): return IO_WOULD_BLOCK
	for i in range(q.requests.length):
		if (q.requests[i] == r):
			list_remove_at[fake_fs_request*](q.requests, i)
			q.bytes = q.bytes - r.cost
			free(r.data)
			free(r)
			return IO_OK
	return IO_IO_ERROR


void fake_fs_async_free(fake_fs_async* q):
	for i in range(q.requests.length):
		fake_fs_request* r = q.requests[i]
		free(r.data)
		free(r)
	list_free[fake_fs_request*](q.requests)
	free(q)
