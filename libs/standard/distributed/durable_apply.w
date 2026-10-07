/*
Durable application adapter for a single serialized LSM owner (#522).
The application computes a batch without external effects, then commits
its mutations, applied Raft index/term and retained request result in
ONE WAL record and syncs it before releasing the response. A duplicate
request consumes its new log index but never repeats its batch.

Reserve all keys starting with @raft/ for this adapter. Request ids are
stable, globally unique text chosen by the application. Results remain
until the application's explicit retention policy deletes them; ids
must never be reused once forgotten. Check retained results BEFORE
computing a non-idempotent batch. Unknown outcome on any failed write
requires reopening the store; retry with the same request id.

Use the same store export for application snapshot data: position and
retained results then travel atomically with user data. Install through
lsm_import, validate the resulting durable position against the Raft
snapshot index before accepting reads or delivering later entries.
This does not make an external payment/email transactional: encode an
outbox item in the batch and use an idempotent external consumer.
*/
import libs.standard.distributed.lsm
import libs.standard.distributed.lsm_stream
import libs.standard.distributed.raft


const int APPLY_ERROR = -1
const int APPLY_COMMITTED = 1
const int APPLY_DUPLICATE = 2


int durable_apply_reserved(char* key):
	return mem_starts_with(key, strlen(key), 0, c"@raft/")


# -1 on a failed/corrupt read, otherwise last durable applied index.
int durable_apply_position(lsm* store, u64* term_out):
	if (lsm_failed(store)): return -1
	char* value = 0
	int len = 0
	int status = lsm_get_status(store, c"@raft/applied", &value, &len)
	if (status == LSM_GET_ERROR): return -1
	if (status == LSM_GET_ABSENT):
		u64_set_int(term_out, 0)
		return 0
	if (len != 12):
		free(value)
		return -1
	int index = load_le32(value)
	u64_load_le(term_out, value + 4)
	free(value)
	if (index < 0): return -1
	return index


# Three-way lookup: LSM_GET_*; caller owns result on FOUND.
int durable_apply_result(lsm* store, char* request_id, char** result, int* length):
	if (lsm_failed(store)): return LSM_GET_ERROR
	char* key = strjoin(c"@raft/result/", request_id)
	int status = lsm_get_status(store, key, result, length)
	free(key)
	return status


# The caller supplies the next COMMITTED entry's conceptual index and
# term. It retains ownership of batch/result. Even empty/no-op/rejected
# commands need a position-only batch, with request_id = null.
int durable_apply_commit(lsm* store, int index, u64* term, char* request_id, lsm_batch* batch, char* result, int result_len):
	if (lsm_failed(store) || result_len < 0 || result_len > wal_max_record() - 128): return APPLY_ERROR
	u64* old_term = u64_new()
	int applied = durable_apply_position(store, old_term)
	int term_ok = u64_cmp(term, old_term) >= 0
	u64_free(old_term)
	if (applied < 0 || index <= 0 || index - 1 != applied || term_ok == 0): return APPLY_ERROR
	int duplicate = 0
	if (request_id != 0):
		if (strlen(request_id) == 0 || strlen(request_id) > 1024): return APPLY_ERROR
		char* retained = 0
		int retained_len = 0
		int status = durable_apply_result(store, request_id, &retained, &retained_len)
		if (status == LSM_GET_ERROR): return APPLY_ERROR
		if (status == LSM_GET_FOUND):
			duplicate = 1
			free(retained)
	lsm_batch* owned = lsm_batch_new()
	int valid = 1
	if (duplicate == 0):
		for i in range(batch.keys.length):
			if (durable_apply_reserved(batch.keys[i])): valid = 0
			if (batch.ops[i] == lsm_tag_put): lsm_batch_put(owned, batch.keys[i], batch.values[i], batch.value_lens[i])
			else: lsm_batch_delete(owned, batch.keys[i])
		if (request_id != 0):
			char* key = strjoin(c"@raft/result/", request_id)
			lsm_batch_put(owned, key, result, result_len)
			free(key)
	char[12] position
	store_le32(position, index)
	u64_save_le(&position[4], term)
	lsm_batch_put(owned, c"@raft/applied", position, 12)
	int ok = 0
	if (valid && owned.encoded_len <= wal_max_record()):
		ok = lsm_apply_batch(store, owned)
		if (ok): ok = lsm_sync(store)
		# Auto-flush can fail before manifest publication after the batch
		# already reached the memtable. Never expose that applied marker
		# as durable on this handle, even when lsm_flush stayed retryable.
		if (ok == 0): store.failed = 1
	lsm_batch_free(owned)
	if (ok == 0): return APPLY_ERROR
	if (duplicate): return APPLY_DUPLICATE
	return APPLY_COMMITTED


# Call after installing a Raft snapshot into the same store. A mismatch
# is fatal to the apply loop; never skip ahead using raft.last_applied.
int durable_apply_snapshot_matches(lsm* store, u64* index, u64* term):
	u64* stored_term = u64_new()
	int applied = durable_apply_position(store, stored_term)
	int ok = applied >= 0 && u64_fits_int(index) && applied == u64_to_int(index) && u64_eq(term, stored_term)
	u64_free(stored_term)
	return ok


# Install a pending blob/file snapshot and verify the application position
# before clearing the Raft read/apply barrier. Any failure is fail-stop;
# preserve pending state and recover from the durable Raft WAL before retrying.
int durable_apply_install_pending(raft* r, lsm* store):
	if (raft_has_pending_snapshot(r) == 0): return 1
	if (u64_fits_int(r.pending_snap_index) == 0): return 0
	char* position = malloc(12)
	store_le32(position, u64_to_int(r.pending_snap_index))
	u64_save_le(position + 4, r.snap_last_term)
	snapshot_file* source = r.pending_snap_file
	int temporary = 0
	if (cast(int, source) == 0):
		temporary = 1
		source = snapshot_file_new(store.ops, store.prefix)
		if (cast(int, source) != 0):
			if (snapshot_file_append(source, r.pending_snap_data, r.pending_snap_len) == 0): source.failed = 1
	int installed = 0
	if (cast(int, source) != 0): installed = lsm_import_file_checked(store, source, c"@raft/applied", position, 12)
	if (temporary): snapshot_file_free(source)
	free(position)
	if (installed == 0):
		store.failed = 1
		return 0
	snapshot_file_free(r.pending_snap_file)
	r.pending_snap_file = 0
	if (r.pending_snap_data != 0): free(r.pending_snap_data)
	r.pending_snap_data = 0
	r.pending_snap_len = 0
	u64_set_zero(r.pending_snap_index)
	return 1
