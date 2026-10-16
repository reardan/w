import lib.lib

struct InspectPair:
	int32 negative
	uint8 small

struct InspectNode:
	int value
	InspectNode* next
	InspectPair pair

int inspect_global = 17

int main():
	InspectNode first
	InspectNode second
	first.value = 42
	first.next = &second
	first.pair.negative = -7
	first.pair.small = 255
	second.value = 99
	second.next = &first
	second.pair.negative = -8
	second.pair.small = 3
	InspectNode* node = &first
	InspectNode* nil = 0
	InspectNode* bad = cast(InspectNode*, 1)
	int* protected = cast(int*, mmap(0, 4096, 0, 34))
	debugger
	first.value = 43
	debugger
	munmap(cast(int, protected), 4096)
	return 0
