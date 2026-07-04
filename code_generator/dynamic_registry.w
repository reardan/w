/*
Registry of shared libraries and imported functions requested with the
c_lib / extern statements. The grammar fills it while parsing; the ELF
writer (elf_dynamic.w) drains it at finish time to build .dynamic and the
relocation tables.

Entries are stored in word-sized slots (heap pointers and vaddrs both fit
in the host word), indexed with save_i / load_i so the tables work whether
the compiler itself runs as x86 or x64.
*/
import code_generator.code_emitter
import code_generator.integer
import lib.lib


int dyn_max_libs():
	return 64


int dyn_max_imports():
	return 4096


# Sonames requested with c_lib (each becomes a DT_NEEDED entry).
char* dyn_lib_names
int dyn_lib_count

# Imported functions: name and the vaddr of the GOT slot the loader fills.
char* dyn_import_names
char* dyn_import_got
int dyn_import_count


void dyn_init():
	if (dyn_lib_names == 0):
		dyn_lib_names = malloc(dyn_max_libs() * word_size)
		dyn_import_names = malloc(dyn_max_imports() * word_size)
		dyn_import_got = malloc(dyn_max_imports() * word_size)


int dyn_has_imports():
	return dyn_import_count > 0


void dyn_add_lib(char* soname):
	dyn_init()
	if (dyn_lib_count >= dyn_max_libs()):
		error("too many c_lib entries")
	save_i(dyn_lib_names + dyn_lib_count * word_size, cast(int, strclone(soname)), word_size)
	dyn_lib_count = dyn_lib_count + 1


char* dyn_lib_name(int i):
	return cast(char*, load_i(dyn_lib_names + i * word_size, word_size))


# Returns the import's index, which is also its .dynsym index minus one.
int dyn_add_import(char* name, int got_vaddr):
	dyn_init()
	if (dyn_import_count >= dyn_max_imports()):
		error("too many extern imports")
	save_i(dyn_import_names + dyn_import_count * word_size, cast(int, strclone(name)), word_size)
	save_i(dyn_import_got + dyn_import_count * word_size, got_vaddr, word_size)
	int index = dyn_import_count
	dyn_import_count = dyn_import_count + 1
	return index


char* dyn_import_name(int i):
	return cast(char*, load_i(dyn_import_names + i * word_size, word_size))


int dyn_import_got_vaddr(int i):
	return load_i(dyn_import_got + i * word_size, word_size)
