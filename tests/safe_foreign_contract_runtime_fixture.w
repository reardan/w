import tests.safe_foreign_contract_module unsafe "de6fb83c6c7d906f3ed677c7718194a649d757a222a019b4aa0ab3bc21da999e"
import lib.memory_debug
import lib.safe
import lib.safe_owned_vector


struct ForeignHolder:
	own ForeignHandle* handle


int foreign_early(int stop):
	for i in range(6):
		own ForeignHandle* h = foreign_handle_new(i)
		if (i == 1): continue
		if (i == stop): return foreign_handle_read(h)
		if (i == 4): break
	return 0


int foreign_owned_storage():
	int before = foreign_handle_drop_count()
	for round in range(3):
		own WOwnedBuffer[ForeignHandle]* values = owned_buffer_new[ForeignHandle](4)
		owned_buffer_push[ForeignHandle](values, foreign_handle_new(1))
		owned_buffer_push[ForeignHandle](values, foreign_handle_new(2))
		int sum = 0
		for refmut ForeignHandle* value in values:
			int number = foreign_handle_read(value) + 1
			foreign_handle_write(value, number)
			sum += foreign_handle_read(value)
		if (sum != 5): return 1
	return foreign_handle_drop_count() - before - 6


int foreign_exercise():
	int before = foreign_handle_drop_count()
	for i in range(100):
		own ForeignHolder* held = new ForeignHolder(foreign_handle_new(i))
		foreign_handle_write(held.handle, i + 1)
		if (foreign_handle_read(held.handle) != i + 1): return 1
		if (foreign_early(2) != 2): return 2
		if (foreign_early(5) != 0): return 3
	if (foreign_handle_drop_count() - before != 900): return 4
	return 0


int main():
	int before = 0
	unsafe:
		malloc_force_debug_mode()
		before = debug_alloc_report_leaks()
	int result = foreign_exercise() + foreign_owned_storage()
	if (result):
		safe_println_int(result)
		return result
	int after = 0
	unsafe: after = debug_alloc_report_leaks()
	return after - before
