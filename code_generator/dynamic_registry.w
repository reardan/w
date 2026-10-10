/*
Registry of shared libraries and imported functions requested with the
c_lib / extern statements. The grammar fills it while parsing; the ELF
writer (elf_dynamic.w) drains it at finish time to build .dynamic and the
relocation tables.

Names are host pointers, stored at __word_size__ even when cross-compiling
to a narrower target. GOT addresses use the target's word_size because
they describe the emitted image, not the compiler's own heap.
*/
import code_generator.code_emitter
import code_generator.integer
import lib.lib


const int dyn_max_libs = 64
const int dyn_max_imports = 4096


# Sonames requested with c_lib (each becomes a DT_NEEDED entry).
char* dyn_lib_names
int dyn_lib_count

# Imported symbols: name, the vaddr the loader writes (a GOT slot for
# functions, the copy space for data objects), the symbol binding
# (1 = global, 2 = weak), the ELF symbol type (2 = func, 1 = object) and
# the object size (0 for functions).
char* dyn_import_names
char* dyn_import_got
char* dyn_import_binding
char* dyn_import_symtype
char* dyn_import_size
int dyn_import_count

# Which library each import belongs to: the index of the most recent c_lib
# at declaration time, -1 when none was declared yet. ELF symbol resolution
# is global, so elf_dynamic.w ignores this; container formats that bind
# imports per library (the PE import directory, a future Mach-O bind table)
# group by it.
char* dyn_import_lib


void dyn_init():
	if (dyn_lib_names == 0):
		dyn_lib_names = cast(char*, malloc(dyn_max_libs * __word_size__))
		dyn_import_names = cast(char*, malloc(dyn_max_imports * __word_size__))
		dyn_import_got = cast(char*, malloc(dyn_max_imports * word_size))
		dyn_import_binding = cast(char*, malloc(dyn_max_imports * 4))
		dyn_import_symtype = cast(char*, malloc(dyn_max_imports * 4))
		dyn_import_size = cast(char*, malloc(dyn_max_imports * 4))
		dyn_import_lib = cast(char*, malloc(dyn_max_imports * 4))


int dyn_has_imports():
	return dyn_import_count > 0


# Reserve the in-image slot the loader fills with the resolved import
# address and return its vaddr. On ELF targets this is a GOT word fixed up
# by a GLOB_DAT relocation. On the win64 target the slot doubles as the
# import's one-entry IAT (FirstThunk array): the extra zero word keeps the
# array null-terminated for loaders that walk it, and pe_64.w points one
# import descriptor at each slot at finish time.
# Number of GOT words allocated below data_offset on the Linux ELF
# targets (dyn_emit_import_slot); the ELF writer covers them with
# PT_GNU_RELRO.
int dyn_relro_slots


# Bytes the RELRO GOT occupies below data_offset, rounded up to whole
# pages: the loader can only mprotect page ranges, and nothing else
# shares those pages. 0 when nothing was imported.
int dyn_relro_size():
	return (dyn_relro_slots * word_size + 4095) & (0 - 4096)


int dyn_emit_import_slot():
	# Linux ELF (issue #537): the GOT grows down from data_offset, one
	# word per slot, into pages of its own at the bottom of the R+W data
	# load. Every slot is written by the loader's GLOB_DAT relocations
	# before the entry point and never again, so the ELF writer marks
	# those pages PT_GNU_RELRO and ld.so mprotects them read-only once
	# relocation is done. Growing down keeps every slot's vaddr final the
	# moment it is allocated, without knowing the import count up front.
	if (data_split && (target_os == 0)):
		dyn_relro_slots = dyn_relro_slots + 1
		return data_offset - dyn_relro_slots * word_size
	# W^X targets (data_split) map the code stream read-execute, so the
	# loader-written slot must live in the RW data segment instead. The
	# win64 target still gets its zero terminator word after the slot,
	# keeping each one-entry FirstThunk array null-terminated even when
	# the next import's slot is emitted right behind it.
	if (data_split):
		int pad = datapos & (word_size - 1)
		if (pad != 0): emit_data_zeros(word_size - pad)
		int data_slot_vaddr = emit_data_zeros(word_size)
		if (target_os == 2): emit_data_zeros(8)
		return data_slot_vaddr
	int slot_vaddr = code_offset + codepos
	emit_zeros(word_size)
	if (target_os == 2): emit_zeros(8)
	return slot_vaddr


void dyn_add_lib(char* soname):
	dyn_init()
	if (dyn_lib_count >= dyn_max_libs): error(c"too many c_lib entries")
	save_ptr(dyn_lib_names + dyn_lib_count * __word_size__, cast(int, strclone(soname)))
	dyn_lib_count = dyn_lib_count + 1


char* dyn_lib_name(int i):
	return cast(char*, load_ptr(dyn_lib_names + i * __word_size__))


# Returns the import's index, which is also its .dynsym index minus one.
int dyn_add_import(char* name, int got_vaddr):
	dyn_init()
	if (dyn_import_count >= dyn_max_imports): error(c"too many extern imports")
	save_ptr(dyn_import_names + dyn_import_count * __word_size__, cast(int, strclone(name)))
	save_i(dyn_import_got + dyn_import_count * word_size, got_vaddr, word_size)
	save_i(dyn_import_binding + dyn_import_count * 4, 1, 4)
	save_i(dyn_import_symtype + dyn_import_count * 4, 2, 4)
	save_i(dyn_import_size + dyn_import_count * 4, 0, 4)
	save_i(dyn_import_lib + dyn_import_count * 4, dyn_lib_count - 1, 4)
	int index = dyn_import_count
	dyn_import_count = dyn_import_count + 1
	return index


# Weak import: the loader leaves the GOT slot null instead of failing when
# the library does not export the symbol. Used for bulk header imports,
# where a broad header may declare functions the library does not provide.
int dyn_add_import_weak(char* name, int got_vaddr):
	int index = dyn_add_import(name, got_vaddr)
	save_i(dyn_import_binding + index * 4, 2, 4)
	return index


# Imported data object (extern without a parameter list): copy_vaddr is
# size bytes reserved in the image; the loader's COPY relocation fills it
# with the shared library's initial value before the entry point runs, and
# the library's own references rebind to this copy (symbol interposition),
# so both sides share one storage location. Weak imports the library does
# not export are left zeroed instead of failing.
int dyn_add_import_data(char* name, int copy_vaddr, int size, int weak):
	# The PE loader has no COPY-relocation equivalent; imported data would
	# need __imp_-style indirection, which is not implemented yet.
	if (target_os == 2): error(c"imported data objects are not supported on the win64 target")
	int index = dyn_add_import(name, copy_vaddr)
	if (weak): save_i(dyn_import_binding + index * 4, 2, 4)
	save_i(dyn_import_symtype + index * 4, 1, 4)
	save_i(dyn_import_size + index * 4, size, 4)
	return index


char* dyn_import_name(int i):
	return cast(char*, load_ptr(dyn_import_names + i * __word_size__))


int dyn_import_got_vaddr(int i):
	return load_i(dyn_import_got + i * word_size, word_size)


int dyn_import_get_binding(int i):
	return load_i(dyn_import_binding + i * 4, 4)


int dyn_import_get_symtype(int i):
	return load_i(dyn_import_symtype + i * 4, 4)


int dyn_import_get_size(int i):
	return load_i(dyn_import_size + i * 4, 4)


int dyn_import_get_lib(int i):
	# Preserve the -1 sentinel for externs declared before any c_lib.
	# load_i zero-extends 4-byte slots on a 64-bit host.
	return load_int32(dyn_import_lib + i * 4)
