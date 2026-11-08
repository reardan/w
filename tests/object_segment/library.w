# Segment-relative accesses for tests/object_segment_test.w: per-CPU
# style data addressed through %gs (and %fs) from W, built with
# --emit=obj --freestanding --c-abi and driven by main.c, which points
# the segment base at a copy of the data with arch_prctl.

struct percpu_hot:
	void* current
	int32 preempt_count
	int32 cpu_number
	uint16 flags
	int16 delta
	uint8 small
	int8 tiny
	int16 pad    # C's alignment padding before wide (W packs fields)
	int64 wide


# Defined by main.c: the per-CPU template (its address is each field's
# offset from the segment base) and plain flat data.
extern __seg_gs percpu_hot seg_hot
extern percpu_hot flat_hot
extern int64 counter
extern int64[] counters


# A field of a segment global.
int32 w_cpu_number():
	return seg_hot.cpu_number


void* w_current():
	return seg_hot.current


void w_set_current(void* task):
	seg_hot.current = task


# Read-modify-write of a segment field, as a compound assignment and
# as an increment statement.
int32 w_preempt_add(int32 v):
	seg_hot.preempt_count += v
	seg_hot.preempt_count++
	return seg_hot.preempt_count


# Every width, signed and unsigned, through a segment pointer that a C
# translator would build from a flat address (C's '*(T __seg_gs *)&x').
int64 w_widths():
	__seg_gs percpu_hot* p = cast(__seg_gs percpu_hot*, cast(uint64, &flat_hot))
	return p.flags + p.delta + p.small + p.tiny + p.wide


void w_store_widths(int64 v):
	__seg_gs percpu_hot* p = cast(__seg_gs percpu_hot*, cast(uint64, &flat_hot))
	p.flags = cast(uint16, v)
	p.delta = cast(int16, 0 - v)
	p.small = cast(uint8, v + 1)
	p.tiny = cast(int8, 0 - v - 1)
	p.wide = v * 1000


# A scalar through a cast pointer: '*(int64 __seg_gs *)&counter'.
int64 w_counter():
	return *cast(__seg_gs int64*, cast(uint64, &counter))


void w_set_counter(int64 v):
	*cast(__seg_gs int64*, cast(uint64, &counter)) = v


# A pointer object that itself lives in the segment space: '__seg_gs(T*)'.
void* w_current_by_pointer():
	__seg_gs(void*)* slot = cast(__seg_gs(void*)*, cast(uint64, &flat_hot))
	return *slot


# Indexing a segment pointer in a loop (register-resident locals).
int64 w_sum_counters(int n):
	__seg_gs int64* p = cast(__seg_gs int64*, cast(uint64, &counters[0]))
	int64 total = 0
	for i in range(n):
		total = total + p[i]
		p[i] = p[i] + 1
	return total


# The %fs space works the same way.
int32 w_fs_cpu_number():
	__seg_fs percpu_hot* p = cast(__seg_fs percpu_hot*, cast(uint64, &flat_hot))
	p.tiny = 5
	return p.cpu_number + p.tiny


# The flat address of a segment global: no prefix, just the offset.
uint64 w_seg_hot_offset():
	return cast(uint64, &seg_hot.preempt_count)
