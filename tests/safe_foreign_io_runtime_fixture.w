import lib.safe_foreign
import lib.memory_debug


type ForeignRead = fn[](int, refmut byte[]) -> int


int exercise():
	for i in range(30):
		own int* amount = new int
		*amount = i
		byte[3] source
		source[0] = cast(byte, 65)
		source[1] = cast(byte, 0)
		source[2] = cast(byte, 66)
		byte[5] destination
		for j in range(5): destination[j] = cast(byte, 127)
		int descriptor = -1
		unsafe:
			if __word_size__ == 8: descriptor = create_file(c"bin/foreign_runtime64", 384)
			else: descriptor = create_file(c"bin/foreign_runtime32", 384)
		if descriptor < 0: return 10
		int written = foreign_write(descriptor, source)
		unsafe:
			close(descriptor)
			if __word_size__ == 8: descriptor = open(c"bin/foreign_runtime64", 0, 0)
			else: descriptor = open(c"bin/foreign_runtime32", 0, 0)
		if descriptor < 0: return 11
		ForeignRead* callback = foreign_read
		refmut byte[] view = destination
		int count = callback(descriptor, view[1:4])
		int eof = foreign_read(descriptor, view)
		unsafe:
			close(descriptor)
			if __word_size__ == 8: unlink(c"bin/foreign_runtime64")
			else: unlink(c"bin/foreign_runtime32")
		if written != 3 || count != 3 || eof != 0: return 1
		if view[0] != cast(byte, 127) || view[4] != cast(byte, 127): return 2
		if view[1] != cast(byte, 65) || view[2] != cast(byte, 0) || view[3] != cast(byte, 66): return 3
		if foreign_read(-1, view) >= 0 || foreign_write(-1, source) >= 0: return 4
		if foreign_read(-1, view[0:0]) != 0 || foreign_write(-1, view[0:0]) != 0: return 5
		if *amount != i: return 6
	return 0


int main():
	int before = 0
	unsafe:
		before = debug_alloc_report_leaks()
	int result = exercise()
	int after = 0
	unsafe:
		after = debug_alloc_report_leaks()
	if result: return result
	return after - before
