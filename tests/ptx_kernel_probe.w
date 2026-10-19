# Kernel-body shapes for tests/ptx_kernel_test.w: exercises the PTX
# emitter paths ordinary gpu fixtures never reach -- binary operands
# complex enough to save/restore %bx and spill stack slots, compound
# assignments to non-promoted locals, 32-bit bitwise ops, unsigned
# compares, truthy while conditions, unguarded bounds traps,
# float<->int conversions in both directions and widths, float64
# negation, and the peephole/promotion machinery those sequences feed.
struct ptx_cell:
	int64 big
	int32 small
	float32 weight
	float64 ratio

struct ptx_arr:
	int64[4] data
	int32 tag

kernel ptx_arith(ptx_cell* cells, int n):
	int i = thread_idx()
	if (i < n):
		int64 acc = cells[i].big
		int32 mask = 0xff
		acc = cells[i].big * cells[i].big + cells[i].small * cells[i].small
		acc = (acc * 2 + 1) * (acc + 3) - acc
		acc -= (acc >> 2) | (acc << 7)
		acc &= ~acc
		acc += 17
		mask ^= 0x5a
		mask &= 0x30
		mask |= 0x01
		cells[i].small = mask
		cells[i].big = acc * 2
		cells[n].big = 0

kernel ptx_slots(ptx_cell* cells, int n):
	int i = thread_idx()
	int64 sum = 0
	int64* p = &sum
	while (sum):
		sum += cells[i].big
		*p = *p - 1
		i = i + 1
	if (sum):
		i = i + 1
	if (i < n):
		cells[i].big = sum

kernel ptx_unsigned(ptx_cell* cells, int n, uint64* out):
	int i = thread_idx()
	if (i < n):
		uint64 a = cast(uint64, cells[i].big) + 9
		uint64 b = cast(uint64, n) * 3
		if (a < b):
			out[i] = cast(int64, a)
		else:
			if (a >= b):
				out[i] = cast(int64, b)
			else:
				out[i] = 0
		if (a <= b): out[i] = out[i] + 1
		if (a > b): out[i] = out[i] + 2
		int eq = (a == b)
		int gt = (a > b)
		if (eq): out[i] = out[i] + 4
		if (gt + eq > 1): out[i] = out[i] + 8
		int64 s1 = cells[i].big
		int sg = (s1 > 0)
		int se = (s1 == 0)
		if (sg): out[i] = out[i] + 16
		if (se): out[i] = out[i] + 32
		if ((i < 0) || (n < 0)): out[i] = 99

kernel ptx_float(ptx_cell* cells, int n):
	int i = thread_idx()
	if (i < n):
		float32 w = cells[i].weight
		float64 r = cells[i].ratio
		float64 r2 = cells[i + 1].ratio
		int64 k = cells[i].big
		w = w * 2.0 + cast(float32, k)
		w = cast(float32, cells[i].big * 3) * (w + cells[i + 1].weight)
		r = -r + cast(float64, w)
		r = r + cast(float64, w * 0.5)
		r = cast(float64, cells[i].big) - r
		k = cast(int64, r) + cast(int64, w)
		if (r < r2): k = k + 1
		if (r < k): k = k + 2
		if (k > r): k = k + 4
		if (k < r): k = k + 8
		if (w < k): k = k + 16
		if (k < w): k = k + 32
		cells[i].weight = -w
		cells[i].ratio = r * 0.5 + r
		cells[i].big = k

kernel ptx_arrays(ptx_arr* arrs, int n):
	int i = thread_idx()
	if (i < n):
		ptx_arr item = arrs[i]
		item.data[0] = item.data[0] + item.tag
		arrs[i] = item
		arrs[i + 1] = arrs[i]
		debugger;

kernel ptx_deep(ptx_cell* cells, int n):
	int i = thread_idx()
	if (i < n):
		int64 total = cells[i].big + cells[i + 1].big + cells[i + 2].big + cells[i + 3].big + cells[i + 4].big + cells[i + 5].big + cells[i + 6].big + cells[i + 7].big + cells[i + 8].big + cells[i + 9].big + cells[i + 10].big + cells[i + 11].big
		cells[i].big = total

kernel ptx_copy(ptx_cell* cells, int n):
	int i = thread_idx()
	if (i < n):
		ptx_cell local = cells[i]
		local.big = local.big + 1
		cells[i] = local
		cells[i + 1] = cells[i]

kernel ptx_for(ptx_cell* cells, int n):
	int i = thread_idx()
	int64 total = 0
	for j in range(4):
		total += cells[i + j].big
		for q in range(3):
			total = total + q
	cells[i].big = total

int main():
	return 0

