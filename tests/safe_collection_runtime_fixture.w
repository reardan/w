# The unchecked harness observes cleanup around checked collection functions.
import lib.safe_buffer
import lib.memory_debug


struct CollectionOwner:
	own WIntBuffer* numbers
	own WByteString* text
	int tag


struct CollectionSnapshot:
	ref[data] int[] values
	int tag


ref[a] CollectionSnapshot collection_snapshot(ref[a] int[] values, int tag):
	return CollectionSnapshot(values, tag)


ref[a] int[] collection_extract(ref[a] CollectionSnapshot value):
	return value.values


int collection_read(int before, ref int[] values, int after):
	return before + values.length + values[0] + after


own CollectionOwner* collection_move(own CollectionOwner* value):
	return value


int collection_exercise():
	own WIntBuffer* numbers = int_buffer_new()
	int i = 0
	while i < 100:
		int_buffer_push(numbers, i + 3)
		i = i + 1
	ref CollectionSnapshot snapshot = collection_snapshot(int_buffer_view(numbers), 7)
	ref int[] values = snapshot.values
	if values.length != 100: return 1
	if values[0] != 3: return 2
	if values[99] != 102: return 3
	if snapshot.tag != 7: return 4
	if collection_read(2, collection_extract(collection_snapshot(int_buffer_view(numbers), 9))[7:14], 4) != 23: return 5
	int[3] fixed
	fixed[0] = 11
	fixed[1] = 13
	fixed[2] = 17
	ref CollectionSnapshot from_array = CollectionSnapshot(fixed, 5)
	ref int[] array_values = from_array.values
	if array_values.length != 3: return 6
	if array_values[2] != 17: return 7
	i = 0
	while i < 200:
		if collection_read(2, collection_snapshot(int_buffer_view(numbers), 1).values[4:8], 3) != 16: return 8
		i = i + 1
	byte[3] initial
	initial[0] = cast(byte, 65)
	initial[1] = cast(byte, 0)
	initial[2] = cast(byte, 90)
	own WByteString* text = byte_string_from(initial)
	ref byte[] chars = byte_string_view(text)
	if chars.length != 3: return 9
	if chars[0] != cast(byte, 65): return 10
	if chars[1] != cast(byte, 0): return 11
	if chars[2] != cast(byte, 90): return 12
	return 0


int collection_drop_nested():
	own WIntBuffer* numbers = int_buffer_new()
	int_buffer_push(numbers, 7)
	own WByteString* text = byte_string_new()
	byte_string_push(text, cast(byte, 65))
	own CollectionOwner* owner = new CollectionOwner(numbers, text, 42)
	own CollectionOwner* moved = collection_move(owner)
	return moved.tag


int main():
	int baseline = debug_alloc_report_leaks()
	if collection_exercise() != 0: return 1
	if debug_alloc_report_leaks() != baseline: return 2
	if collection_drop_nested() != 42: return 3
	return debug_alloc_report_leaks() - baseline
