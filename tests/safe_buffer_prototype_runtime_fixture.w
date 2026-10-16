import lib.safe_buffer
import lib.memory_debug

# A matching declaration must preserve the audited implementation, including
# when it occurs after a checked body has emitted its automatic cleanup.
void __w_byte_string_drop(WByteString* value);

int prototype_dispose():
	own WIntBuffer* values = int_buffer_new()
	own WByteString* text = byte_string_new()
	int i = 0
	while (i < 100):
		int_buffer_push(values, i)
		byte_string_push(text, cast(byte, i))
		i = i + 1
	return int_buffer_get(values, 99) + cast(int, byte_string_get(text, 99)) - 198

void __w_int_buffer_drop(WIntBuffer* value);

int main():
	int before = debug_alloc_report_leaks()
	if (prototype_dispose() != 0): return 1
	return debug_alloc_report_leaks() - before
