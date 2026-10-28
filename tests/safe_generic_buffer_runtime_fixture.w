import lib.safe_vector
import lib.memory_debug


struct BufferPair:
	int left
	int right


own WBuffer[T]* buffer_single[T](T value):
	own WBuffer[T]* buffer = buffer_new[T]()
	buffer_push[T](buffer, value)
	return buffer


int exercise():
	int total = 0
	for i in range(30):
		own WBuffer[BufferPair]* pairs = buffer_new[BufferPair]()
		for j in range(20): buffer_push[BufferPair](pairs, BufferPair(j, 2 * j))
		refmut BufferPair[] values = buffer_view_mut[BufferPair](pairs)
		for j in range(values.length): values[j].left += i
		ref BufferPair[] shared = values
		for j in range(shared.length): total += shared[j].left + shared[j].right
		BufferPair last = buffer_pop[BufferPair](pairs)
		total += last.left + last.right
		buffer_clear[BufferPair](pairs)
		if buffer_length[BufferPair](pairs) != 0: return -1
		own WBuffer[byte]* bytes = buffer_single[byte](cast(byte, 7))
		total += cast(int, buffer_pop[byte](bytes))
	return total


struct BufferBox:
	own WBuffer[int]* values


int exercise_exits():
	int total = 0
	for i in range(10):
		own WBuffer[int]* local = buffer_single[int](i)
		if i % 2 == 0: continue
		if i == 7: break
		total += buffer_pop[int](local)
	own WBuffer[int]* replaced = buffer_single[int](7)
	replaced = buffer_single[int](11)
	own WBuffer[int]* moved = replaced
	total += buffer_pop[int](moved)
	own BufferBox* box = new BufferBox(buffer_single[int](13))
	own WBuffer[int]* child = box.values
	box.values = buffer_new[int]()
	return total + buffer_pop[int](child)


int main():
	int before = 0
	unsafe:
		malloc_force_debug_mode()
		before = debug_alloc_report_leaks()
	if exercise() != 28155: return 1
	if exercise_exits() != 33: return 2
	int after = 0
	unsafe:
		after = debug_alloc_report_leaks()
	return after - before
