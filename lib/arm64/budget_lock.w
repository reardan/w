# Shared-budget synchronization is qualified on Linux x86/x64 only.
# This small critical section never allocates, blocks on I/O or calls users.
# CAS is a full barrier; release publishes the coherent accounting state.
int budget_lock_supported():
	return 0


void budget_lock_enter(int* word):
	return


void budget_lock_leave(int* word):
	return
