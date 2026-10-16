import lib.safe_buffer
import lib.memory_debug

ref[a] byte[] arena_local_copy(refmut[a] WByteArena* arena):
	byte[3] local
	local[0] = cast(byte, 65)
	local[1] = cast(byte, 0)
	local[2] = cast(byte, 90)
	return byte_arena_copy(arena, local)

int arena_exercise():
	own WByteArena* arena = byte_arena_new()
	byte[1] empty_storage
	ref byte[] storage = empty_storage
	ref byte[] empty = storage[0:0]
	ref byte[] nothing = byte_arena_copy(arena, empty)
	if nothing.length != 0: return 1
	ref byte[] local = arena_local_copy(arena)
	if local.length != 3: return 2
	if local[1] != cast(byte, 0): return 3
	if local[2] != cast(byte, 90): return 4
	byte_arena_reset(arena)
	if byte_arena_length(arena) != 0: return 5
	byte[65] data
	data[0] = cast(byte, 11)
	data[64] = cast(byte, 17)
	int i = 0
	while i < 100:
		ref byte[] copy = byte_arena_copy(arena, data)
		data[0] = cast(byte, 12)
		if copy.length != 65: return 6
		if copy[64] != cast(byte, 17): return 7
		if i == 0:
			if copy[0] != cast(byte, 11): return 8
		i = i + 1
	if byte_arena_length(arena) != 6500: return 9
	byte_arena_release(arena)
	if byte_arena_length(arena) != 0: return 10
	ref byte[] renewed = arena_local_copy(arena)
	if renewed[0] != cast(byte, 65): return 11
	own WByteArena* moved = arena
	ref byte[] last = arena_local_copy(moved)
	return cast(int, last[2]) - 90

int main():
	int before = 0
	unsafe:
		malloc_force_debug_mode()
		before = debug_alloc_report_leaks()
	int result = arena_exercise()
	int after = 0
	unsafe:
		after = debug_alloc_report_leaks()
	return result + after - before
