/*
Two bounded work classes for persistence and maintenance (#522).
The socket owner continues pumping transport/timers while task callers
await executor_run. Each admitted job exclusively owns its store/Raft
state until executor_wait returns, including cancellation. Never tick or
mutate a Raft object while its persistence job holds it. Socket frames
can remain in the bounded transport inbox until the owner resumes.

Do not run maintenance against the same mutable LSM concurrently with
application writes: use an immutable lsm_view, or schedule that store on
one serialized owner. Separate executors reserve capacity; they do not
make a shared store thread-safe. Cost includes retained input/output
bytes, not merely the small job descriptor. Admission is try-only here.
*/
import lib.executor
import libs.standard.distributed.raft_wal
import libs.standard.distributed.storage_maintenance


struct storage_executor:
	executor* commit
	executor* maintenance


storage_executor* storage_executor_new(int commit_bytes, int maintenance_bytes):
	return new storage_executor(executor_new(c"storage-commit", 1, 4, commit_bytes), executor_new(c"storage-maintenance", 1, 1, maintenance_bytes))


void storage_executor_close(storage_executor* workers):
	executor_close(workers.commit, EXEC_CANCEL)
	executor_close(workers.maintenance, EXEC_CANCEL)


# Must wait for all jobs before releasing their arguments or stores.
void storage_executor_free(storage_executor* workers):
	storage_executor_close(workers)
	executor_free(workers.commit)
	executor_free(workers.maintenance)
	free(workers)


struct storage_persist_job:
	raft_wal* log
	raft* node
	list[raft_msg*] staged
	list[raft_msg*] released


int storage_persist_work(void* argument):
	storage_persist_job* job = cast(storage_persist_job*, argument)
	return raft_wal_persist_release(job.log, job.node, job.staged, job.released)


struct storage_compact_job:
	lsm* store
	int max_temp_bytes


int storage_compact_work(void* argument):
	storage_compact_job* job = cast(storage_compact_job*, argument)
	if (lsm_compact_bounded(job.store, job.max_temp_bytes)): return IO_OK
	return IO_IO_ERROR
