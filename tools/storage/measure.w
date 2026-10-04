# Benchmark-only native adapters. No runtime/compiler instrumentation.
import lib.metrics
import libs.standard.distributed.storage_io


int storage_measure_allocations
int storage_measure_allocated_bytes
int storage_measure_reads
int storage_measure_read_bytes
int storage_measure_writes
int storage_measure_write_bytes
int storage_measure_syncs
int storage_measure_sync_us


void* storage_measure_malloc(int size):
	storage_measure_allocations = storage_measure_allocations + 1
	storage_measure_allocated_bytes = storage_measure_allocated_bytes + size
	return malloc_backend(size)


int storage_measure_free(void* p):
	return malloc_backend_free(p)


char* storage_measure_realloc(void* p, int oldlen, int newlen):
	storage_measure_allocations = storage_measure_allocations + 1
	storage_measure_allocated_bytes = storage_measure_allocated_bytes + newlen
	return malloc_backend_realloc(p, oldlen, newlen)


int storage_measure_read(void* self, int fd, char* data, int len, io_result* r):
	int status = file_ops_real_read(0, fd, data, len, r)
	storage_measure_reads = storage_measure_reads + 1
	storage_measure_read_bytes = storage_measure_read_bytes + r.transferred
	return status


int storage_measure_write(void* self, int fd, char* data, int len, io_result* r):
	int status = file_ops_real_write(0, fd, data, len, r)
	storage_measure_writes = storage_measure_writes + 1
	storage_measure_write_bytes = storage_measure_write_bytes + r.transferred
	return status


int storage_measure_sync(void* self, int fd, io_result* r):
	int start = metrics_now_us()
	int status = file_ops_real_sync(0, fd, r)
	storage_measure_syncs = storage_measure_syncs + 1
	storage_measure_sync_us = storage_measure_sync_us + metrics_now_us() - start
	return status


file_ops* storage_measure_ops():
	malloc_hook_set(cast(int, storage_measure_malloc), cast(int, storage_measure_free), cast(int, storage_measure_realloc))
	file_ops* ops = file_ops_real_new()
	ops.read = storage_measure_read
	ops.write = storage_measure_write
	ops.sync = storage_measure_sync
	return ops
