# Audited nominal foreign handle with explicit cleanup and threading rules.
import lib.safe_foreign_owner


struct ForeignHandle:
	int secret
	int* raw


int foreign_handle_drops


void __w_foreign_drop_ForeignHandle(ForeignHandle* value):
	foreign_handle_drops += 1
	free(value.raw)
	free(value)


# Audited assertions: exclusive transfer and concurrent shared reads are safe.
void __w_foreign_send_ForeignHandle(ForeignHandle* value):
	pass


void __w_foreign_sync_ForeignHandle(ForeignHandle* value):
	pass


own ForeignHandle* foreign_handle_new(int value):
	ForeignHandle* handle = new ForeignHandle
	handle.raw = new int
	*handle.raw = value
	return cast(own ForeignHandle*, handle)


int foreign_handle_read(ref ForeignHandle* value):
	return *value.raw


void foreign_handle_write(refmut ForeignHandle* value, int number):
	*value.raw = number


int foreign_handle_drop_count():
	return foreign_handle_drops
