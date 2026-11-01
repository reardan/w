# wbuild: x64
# wbuild: step="bin/wv2 --strict --no-regs --no-inline tests/memory_provenance_thread_test.w -o bin/memory_provenance_thread_plain"
# wbuild: step="bin/memory_provenance_thread_plain"
# wbuild: step="bin/wv2 x64 --strict --inline tests/memory_provenance_thread_test.w -o bin/memory_provenance_thread_inline64"
# wbuild: step="bin/memory_provenance_thread_inline64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/memory_provenance_thread_inline64"
import lib.assert
import lib.thread


struct ProvenanceJob:
	int id
	int ok
	void* handed_in
	void* handed_out


void provenance_thread_worker(void* argument):
	ProvenanceJob* job = cast(ProvenanceJob*, argument)
	int ok = malloc_provenance_size(job.handed_in) == 41
	free(job.handed_in)
	char*[96] slots
	int[96] lengths
	for round in range(16):
		for i in range(96):
			int size = (i + job.id * 7 + round * 13) % 127 + 1
			slots[i] = cast(char*, malloc(size))
			lengths[i] = size
			slots[i][0] = cast(char, job.id)
			if (malloc_provenance_size(slots[i]) != size): ok = 0
		for i in range(96):
			char* old = slots[i]
			int size = lengths[i] + 200
			char* grown = realloc(old, lengths[i], size)
			if (malloc_provenance_size(grown) != size): ok = 0
			if (cast(int, grown[0]) != job.id): ok = 0
			__w_foreign_owner_check(grown, size, 0)
			free(grown)
	job.handed_out = malloc(73)
	job.ok = ok


int main():
	malloc_provenance_enabled = 1
	ProvenanceJob[5] jobs
	wthread*[4] workers
	for i in range(5):
		jobs[i].id = i + 1
		jobs[i].ok = 0
		jobs[i].handed_in = malloc(41)
		jobs[i].handed_out = 0
	for i in range(4):
		workers[i] = thread_spawn(provenance_thread_worker, &jobs[i])
		asserts(c"provenance worker spawned", workers[i] != 0)
	provenance_thread_worker(&jobs[4])
	for i in range(4): assert_equal(0, thread_join(workers[i]))
	for i in range(5):
		assert_equal(1, jobs[i].ok)
		assert_equal(73, malloc_provenance_size(jobs[i].handed_out))
		__w_foreign_owner_check(jobs[i].handed_out, 73, 0)
		free(jobs[i].handed_out)
	assert_equal(0, malloc_provenance_live)
	asserts(c"thread registry lock installed", malloc_provenance_lock_hook != 0)
	asserts(c"thread registry unlock installed", malloc_provenance_unlock_hook != 0)
	return 0
