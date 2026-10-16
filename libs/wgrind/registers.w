# Per-thread integer register shadow. The frontend owns one file per
# application thread and serializes shared-memory events on its context.
# Register numbering and ISA-specific aliases belong to the frontend.
import libs.wgrind.values


struct wg_registers:
	int[16] values
	int[16] undefined
	int[128] origins # one origin per byte, maximum eight bytes per register


void wg_registers_init(wg_registers* r, int origin):
	for i in range(16):
		r.values[i] = 0
		r.undefined[i] = -1
	for i in range(128): r.origins[i] = origin


int wg_register_slice(wg_context* c, int reg, int offset, int size, int site):
	if (c.error): return 0
	if ((reg < 0) || (reg >= 16) || (offset < 0) || (size < 1) || (size > __word_size__) || (offset > __word_size__ - size)):
		return wg_error(c, WG_INCOMPLETE, reg, size, site, 0)
	return 1


int wg_register_read(wg_context* c, wg_registers* r, int reg, int offset, int size, int site, wg_value* out):
	if (wg_register_slice(c, reg, offset, size, site) == 0): return 0
	int shift = offset * 8
	int mask = wg_mask(size)
	int u = (r.undefined[reg] >> shift) & mask
	int origin = 0
	for i in range(size):
		if (((u >> (i * 8)) & 255) && (origin == 0)): origin = r.origins[reg * 8 + offset + i]
	wg_value_set(out, (r.values[reg] >> shift) & mask, u, origin)
	return 1


# clear_upper expresses writes such as x64 EAX, which define RAX's high
# half as zero. Ordinary byte/word writes preserve every untouched bit.
int wg_register_write(wg_context* c, wg_registers* r, int reg, int offset, int size, int clear_upper, int site, wg_value* value):
	if (wg_register_slice(c, reg, offset, size, site) == 0): return 0
	if (clear_upper && (offset != 0)): return wg_error(c, WG_INCOMPLETE, reg, size, site, 0)
	int mask = wg_mask(size)
	int v = value.value & mask
	int u = value.undefined & mask
	int shift = offset * 8
	if (clear_upper):
		r.values[reg] = 0
		r.undefined[reg] = 0
		for i in range(__word_size__): r.origins[reg * 8 + i] = 0
	r.values[reg] = (r.values[reg] & ~(mask << shift)) | (v << shift)
	r.undefined[reg] = (r.undefined[reg] & ~(mask << shift)) | (u << shift)
	for i in range(size):
		int origin = 0
		if ((u >> (i * 8)) & 255): origin = value.origin
		r.origins[reg * 8 + offset + i] = origin
	return 1
