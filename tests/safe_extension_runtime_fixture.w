# The unchecked observer inspects exactly-once drops around checked functions.
# It also makes premature cleanup before a deferred read fault under guards.
import lib.memory_debug
import lib.safe_buffer


struct ExtensionOwnedPair:
	own int* first
	own int* second


own ExtensionOwnedPair* extension_pair(int value):
	own int* first = new int
	own int* second = new int
	*first = value
	*second = value + 1
	return new ExtensionOwnedPair(first, second)


int extension_read(ref ExtensionOwnedPair* pair):
	ref int* first = pair.first
	ref int* second = pair.second
	return *first + *second


void extension_append(refmut int* log, int value):
	*log = *log * 10 + value


void extension_consume(own ExtensionOwnedPair* pair, refmut int* log):
	extension_append(log, extension_read(pair))


int extension_deferred(refmut int* log):
	own ExtensionOwnedPair* pair = extension_pair(2)
	defer extension_append(log, 1)
	defer extension_consume(pair, log)
	return extension_read(pair)


int extension_nested_exits(int limit):
	own ExtensionOwnedPair* outer = extension_pair(0)
	int result = 0
	for i in range(limit):
		own ExtensionOwnedPair* local = extension_pair(i)
		switch i:
			case 0:
				continue
			case 1:
				break
			case 4:
				return result
			default:
				for j in range(3):
					own ExtensionOwnedPair* nested = extension_pair(j)
					if j == 1: break
					result = result + extension_read(nested)
		result = result + extension_read(local)
	return result


int extension_defer_nested_return(refmut int* log, int limit):
	own ExtensionOwnedPair* pair = extension_pair(3)
	defer extension_consume(pair, log)
	for i in range(limit):
		own ExtensionOwnedPair* local = extension_pair(i)
		switch i:
			case 2:
				return extension_read(local)
			default:
				continue
	return 0


void extension_fallthrough(refmut int* log):
	own ExtensionOwnedPair* pair = extension_pair(4)
	defer extension_consume(pair, log)


int extension_observe_deferred():
	int log = 0
	if extension_deferred(&log) != 5: return 1
	if log != 51: return 2
	return 0


int extension_observe_paths():
	int log = 0
	if extension_defer_nested_return(&log, 0) != 0: return 16
	if log != 7: return 17
	log = 0
	if extension_defer_nested_return(&log, 4) != 5: return 18
	if log != 7: return 19
	log = 0
	extension_fallthrough(&log)
	if log != 9: return 20
	return 0


int extension_deferred_push():
	own WOwnedIntBuffer* buffer = owned_int_buffer_new()
	own int* item = new int
	*item = 9
	defer owned_int_buffer_push(buffer, item)
	return *item - 9


int extension_buffer_transfers():
	own WOwnedIntBuffer* source = owned_int_buffer_new()
	own WOwnedIntBuffer* destination = owned_int_buffer_new()
	for i in range(65):
		own int* item = new int
		*item = i
		owned_int_buffer_push(source, item)
	while owned_int_buffer_length(source):
		owned_int_buffer_push(destination, owned_int_buffer_pop(source))
	ref int* first = owned_int_buffer_get(destination, 0)
	if *first != 64: return 1
	own int* last = owned_int_buffer_pop(destination)
	source = owned_int_buffer_new()
	destination = owned_int_buffer_new()
	return *last


int extension_arena_paths():
	own WByteArena* arena = byte_arena_new()
	int total = 0
	for i in range(20):
		byte[32] source
		source[0] = cast(byte, i)
		ref byte[] view = byte_arena_copy(arena, source)
		source[0] = cast(byte, 0)
		total = total + cast(int, view[0])
	byte_arena_reset(arena)
	if byte_arena_length(arena) != 0: return 1
	byte[1] source
	ref byte[] original = source
	ref byte[] empty = byte_arena_copy(arena, original[0:0])
	if empty.length != 0: return 2
	byte_arena_release(arena)
	ref byte[] final_view = byte_arena_copy(arena, source)
	return total + final_view.length - 191


int main():
	int before = debug_alloc_report_leaks()
	int tail = debug_quarantine_tail
	int sequence = debug_alloc_sequence
	if extension_observe_deferred() != 0: return 1
	if debug_alloc_sequence != sequence + 3: return 3
	int link = debug_quarantine_head
	if tail: link = debug_tbl_next[tail - 1]
	if link == 0: return 4
	if debug_tbl_sequence[link - 1] != sequence + 2: return 5
	link = debug_tbl_next[link - 1]
	if link == 0: return 6
	if debug_tbl_sequence[link - 1] != sequence + 1: return 7
	link = debug_tbl_next[link - 1]
	if link == 0: return 8
	if debug_tbl_sequence[link - 1] != sequence + 3: return 9
	if debug_tbl_next[link - 1] != 0: return 10
	if extension_nested_exits(0) != 0: return 11
	if extension_nested_exits(1) != 0: return 12
	if extension_nested_exits(2) != 3: return 13
	if extension_nested_exits(4) != 17: return 14
	if extension_nested_exits(5) != 17: return 15
	if extension_observe_paths() != 0: return 21
	if extension_deferred_push() != 0: return 22
	if extension_buffer_transfers() != 0: return 23
	if extension_arena_paths() != 0: return 24
	return debug_alloc_report_leaks() - before
