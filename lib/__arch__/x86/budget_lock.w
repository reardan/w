# Shared-budget synchronization is qualified on Linux x86/x64 only.
# This small critical section never allocates, blocks on I/O or calls users.
# CAS is a full barrier; release publishes the coherent accounting state.
int budget_lock_supported():
	return 1


void budget_lock_enter(int* word):
	while (atomic_cas(word, 0, 1) != 0):
		while (atomic_load_relaxed(word) != 0):
			continue


void budget_lock_leave(int* word):
	atomic_store(word, 0)
