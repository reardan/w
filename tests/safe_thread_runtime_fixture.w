# Checked spawn/join runtime behavior (#699): payload transfer, join,
# drop-joins, refused spawns destroying their payload, handles moved into
# other threads, and scoped fork-join over lent storage. main returns the
# number of allocations leaked by the measured round.
import lib.memory_debug
import lib.safe_buffer
import lib.safe_thread


struct Payload:
	own int* value
	own WIntBuffer* items


struct Job:
	own Payload* payload
	int index


type Worker = fn[](own Job*) -> int


int run_job(own Job* job):
	ref Payload* payload = job.payload
	ref int* value = payload.value
	ref WIntBuffer* items = payload.items
	int total = *value + job.index
	for i in range(int_buffer_length(items)): total = total + int_buffer_get(items, i)
	return total


own Job* make_job(int index):
	own int* value = new int
	*value = 100
	own WIntBuffer* items = int_buffer_new()
	refmut WIntBuffer* writer = items
	for i in range(4): int_buffer_push(writer, i)
	return new Job(new Payload(value, items), index)


# 100 + index + (0 + 1 + 2 + 3)
int expected(int index):
	return 106 + index


int spawn_join(int index):
	Worker* entry = run_job
	optown WSafeThread* thread = safe_thread_spawn(entry, make_job(index))
	if (!thread): return -1
	own WSafeThread* started = thread
	return safe_thread_join(started)


# The handle leaves scope unjoined; its destructor waits for the child.
int spawn_and_drop(int index):
	Worker* entry = run_job
	optown WSafeThread* thread = safe_thread_spawn(entry, make_job(index))
	if (!thread): return 0
	return 1


# Replacing a present handle joins the previous child first.
int spawn_and_replace():
	Worker* entry = run_job
	optown WSafeThread* thread = safe_thread_spawn(entry, make_job(1))
	thread = safe_thread_spawn(entry, make_job(2))
	if (!thread): return -1
	own WSafeThread* started = thread
	return safe_thread_join(started)


# Hold one live handle per frame until the audited limit refuses a spawn;
# the refused payload is destroyed by the runtime and every held handle
# is joined as the frames return.
int spawn_until_refused(int depth):
	Worker* entry = run_job
	optown WSafeThread* thread = safe_thread_spawn(entry, make_job(depth))
	if (!thread): return depth
	return spawn_until_refused(depth + 1)


struct Relay:
	own WSafeThread* inner


type Joiner = fn[](own Relay*) -> int


int join_relayed(own Relay* relay):
	own WSafeThread* inner = relay.inner
	return safe_thread_join(inner)


# A handle is transferable: another checked thread may join it.
int relay_join(int index):
	Worker* entry = run_job
	optown WSafeThread* thread = safe_thread_spawn(entry, make_job(index))
	if (!thread): return -1
	own WSafeThread* started = thread
	Joiner* joiner = join_relayed
	optown WSafeThread* relay = safe_thread_spawn(joiner, new Relay(started))
	if (!relay): return -1
	own WSafeThread* running = relay
	return safe_thread_join(running)


struct Chunk:
	int start
	int count
	int total


type Sum = fn[](refmut Chunk*) -> int


# Divide and conquer: each level lends two disjoint exclusive halves.
int sum_chunk(refmut Chunk* chunk):
	if (chunk.count <= 64):
		int total = 0
		for i in range(chunk.count): total = total + chunk.start + i
		chunk.total = total
		return 1
	int half = chunk.count / 2
	own Chunk* left = new Chunk(chunk.start, half, 0)
	own Chunk* right = new Chunk(chunk.start + half, chunk.count - half, 0)
	refmut Chunk* first = left
	refmut Chunk* second = right
	Sum* entry = sum_chunk
	int leaves = safe_thread_fork_join(entry, first, second)
	chunk.total = left.total + right.total
	return leaves


struct Table:
	own int* scale
	int offset


type Lookup = fn[](ref Table*) -> int


int lookup(ref Table* table):
	ref int* scale = table.scale
	return *scale + table.offset


int fork_join_round():
	own Chunk* whole = new Chunk(0, 1000, 0)
	refmut Chunk* lent = whole
	Sum* entry = sum_chunk
	int leaves = sum_chunk(lent)
	if (leaves != 16): return 1
	if (whole.total != 499500): return 2
	own int* scale = new int
	*scale = 20
	own Table* table = new Table(scale, 1)
	ref Table* shared = table
	Lookup* reader = lookup
	if (safe_thread_fork_join(reader, shared, shared) != 42): return 3
	return 0


int exercise():
	if (spawn_join(7) != expected(7)): return 1
	if (spawn_and_drop(3) != 1): return 2
	if (spawn_and_replace() != expected(2)): return 3
	if (spawn_until_refused(0) != 64): return 4
	if (spawn_join(9) != expected(9)): return 5
	if (relay_join(4) != expected(4)): return 6
	return fork_join_round()


int main():
	# The first round installs the per-thread heaps; measure the second.
	if (exercise() != 0): return 100
	int before = 0
	unsafe:
		before = debug_alloc_report_leaks()
	int status = exercise()
	if (status != 0): return 100 + status
	int after = 0
	unsafe:
		after = debug_alloc_report_leaks()
	return after - before
