# --emit=obj --freestanding --c-abi layout regressions
# (tests/object_layout_test.w links this with layout_main.c, also through
# 'ld -r'): a static whose record type completes after the extern
# declarations that follow it, a static of a record nesting only an
# empty record ahead of a global in a discarded section, an array only
# a linker script sees, and extern calls that become direct calls.
type pick = fn(int, int) -> int

struct fs_type:

static fs_type rootfs

extern int c_record(uint8* name, int flags)
extern int c_twice(int a, int b)


# Takes the record's address before its body exists.
fs_type* early_rootfs():
	return &rootfs


struct fs_type:
	uint8* name
	int flags
	int extra


struct empty_lock:

struct spinlock:
	empty_lock raw

static spinlock once_lock

@section(".discard.layout")
static int discard_keep = {int 5}

@section(".layout_info")
static uint8[8] layout_info = {uint8 108, uint8 97, uint8 121}


spinlock* layout_lock():
	return &once_lock


int layout_register(uint8* name):
	fs_type* fs = early_rootfs()
	fs.name = name
	fs.flags = 3
	fs.extra = 4
	return c_record(rootfs.name, rootfs.flags + rootfs.extra)


# A function value of an extern keeps reaching it through its slot.
int layout_value_call(int a):
	pick* f = c_twice
	return f(a, 1)
