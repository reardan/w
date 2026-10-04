# wbuild: binary=storage_probe arch=x64
# wbuild: target=storage_native_test
# wbuild: step="bin/wv2 x64 tools/storage/probe.w -o bin/storage_native_probe"
# wbuild: step="python3 tools/storage/native_test.py bin/storage_native_probe" timeout=60000
# Native process-recovery fixture and repeatable storage benchmark driver.
import libs.standard.distributed.durable_apply
import libs.standard.distributed.storage_maintenance
import lib.metrics
import tools.storage.measure


void probe_metric(char* name, int value):
	print(name)
	print(c" ")
	char* number = itoa(value)
	println(number)
	free(number)


void probe_totals():
	probe_metric(c"allocations", storage_measure_allocations)
	probe_metric(c"allocated_bytes", storage_measure_allocated_bytes)
	probe_metric(c"read_calls", storage_measure_reads)
	probe_metric(c"read_bytes", storage_measure_read_bytes)
	probe_metric(c"write_calls", storage_measure_writes)
	probe_metric(c"write_bytes", storage_measure_write_bytes)
	probe_metric(c"sync_calls", storage_measure_syncs)
	probe_metric(c"sync_us", storage_measure_sync_us)
	probe_metric(c"queue_bytes", 0)


int main(int argc, char** args):
	if (argc < 3): return 2
	char* mode = args[1]
	int start = metrics_now_us()
	file_ops* ops = storage_measure_ops()
	wal_recovery report
	lsm* store = lsm_open_policy_with_ops(ops, args[2], 65536, WAL_RECOVER_STRICT_TRUNCATE, &report)
	if (cast(int, store) == 0): return 3
	if (strcmp(mode, c"init") == 0 || strcmp(mode, c"advance") == 0):
		u64* term = u64_new_int(1)
		int index = durable_apply_position(store, term) + 1
		u64_set_int(term, index)
		char* value = itoa(index)
		lsm_batch* batch = lsm_batch_new()
		lsm_batch_put(batch, c"a", value, strlen(value))
		lsm_batch_put(batch, c"b", value, strlen(value))
		int status = durable_apply_commit(store, index, term, value, batch, value, strlen(value))
		lsm_batch_free(batch)
		free(value)
		u64_free(term)
		lsm_close(store)
		if (status != APPLY_COMMITTED): return 4
		return 0
	if (strcmp(mode, c"verify") == 0):
		u64* term = u64_new()
		int index = durable_apply_position(store, term)
		if (index != 1 && index != 2): return 5
		char* expected = itoa(index)
		int len = 0
		char* a = lsm_get(store, c"a", &len)
		char* b = lsm_get(store, c"b", &len)
		if (a == 0 || b == 0 || strcmp(a, expected) != 0 || strcmp(b, expected) != 0): return 6
		char* result = 0
		if (durable_apply_result(store, expected, &result, &len) != LSM_GET_FOUND || strcmp(result, expected) != 0): return 7
		free(a)
		free(b)
		free(result)
		free(expected)
		u64_free(term)
		lsm_close(store)
		return 0
	if (strcmp(mode, c"compact") == 0):
		int ok = lsm_flush(store)
		if (ok): ok = lsm_compact_bounded(store, 16777216)
		lsm_close(store)
		if (ok == 0): return 8
		probe_metric(c"latency_us", metrics_now_us() - start)
		probe_totals()
		return 0
	if (strcmp(mode, c"recover") == 0):
		probe_metric(c"latency_us", metrics_now_us() - start)
		probe_totals()
		lsm_close(store)
		return 0
	if (argc < 5): return 2
	int count = atoi(args[3])
	int durable = atoi(args[4])
	if (count < 1 || count > 100000): return 2
	if (strcmp(mode, c"checksum") == 0):
		char* data = malloc(32768)
		mem_fill[char](data, 'x', 32768)
		for i in range(count):
			int begin = metrics_now_us()
			raft_snapshot_checksum(data, 32768)
			probe_metric(c"latency_us", metrics_now_us() - begin)
		free(data)
		probe_totals()
		lsm_close(store)
		return 0
	if (strcmp(mode, c"decode") == 0):
		for i in range(count):
			int begin = metrics_now_us()
			for j in range(store.table_paths.length):
				sstable* table = sstable_open_with_ops(ops, store.table_paths[j])
				if (cast(int, table) == 0): return 13
				sstable_close(table)
			probe_metric(c"latency_us", metrics_now_us() - begin)
		probe_totals()
		lsm_close(store)
		return 0
	if (strcmp(mode, c"write") == 0 || strcmp(mode, c"read") == 0):
		for i in range(count):
			char* key = itoa(i)
			int begin = metrics_now_us()
			if (strcmp(mode, c"write") == 0):
				if (lsm_put(store, key, c"abcdefghijklmnopqrstuvwxyz012345", 32) == 0): return 9
				if (durable && lsm_sync(store) == 0): return 9
			else:
				int len = 0
				char* value = lsm_get(store, key, &len)
				if (value == 0 || len != 32): return 10
				free(value)
			probe_metric(c"latency_us", metrics_now_us() - begin)
			free(key)
	else if (strcmp(mode, c"scan") == 0):
		char* resume = 0
		int more = 1
		while (more):
			int begin = metrics_now_us()
			lsm_page* page = lsm_scan(store, resume, 128, 8192)
			if (resume != 0): free(resume)
			if (page.ok == 0): return 11
			resume = page.resume
			page.resume = 0
			more = resume != 0
			lsm_page_free(page)
			probe_metric(c"latency_us", metrics_now_us() - begin)
	else: return 2
	if (lsm_sync(store) == 0): return 12
	lsm_close(store)
	probe_totals()
	return 0
