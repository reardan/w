# Guest-memory access is supplied by the execution frontend. A remote
# reader must report failure rather than returning invented zero bytes.
import libs.wgrind.shadow

type wg_reader = fn(int, int, int, int*) -> int


int wg_read_local(int opaque, int address, int size, int* out):
	# Caller has already checked guest accessibility; opaque is unused.
	if ((size < 1) || (size > __word_size__) || (opaque != 0)): return 0
	char* p = cast(char*, address)
	int result = 0
	for i in range(size): result = result | ((p[i] & 255) << (i * 8))
	*out = result
	return 1
