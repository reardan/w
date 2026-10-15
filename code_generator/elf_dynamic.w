/*
Dynamic-linking sections for executables that import shared libraries via
c_lib / extern. Everything is appended to the text PT_LOAD segment at
finish time (all of it is read-only at run time, so a read-execute
mapping is fine) and the reserved PT_INTERP / PT_DYNAMIC program headers
are patched to point at it.

Binding is eager: one GOT slot per import (in the RW data segment under
the W^X split, inline next to its shim otherwise) plus one GLOB_DAT
relocation, so the loader writes the resolved address before the entry
point runs -- no PLT, no lazy resolver. On Linux the GOT slots get whole
pages of their own below the data base, covered by PT_GNU_RELRO, so the
loader makes them read-only once relocation is done (elf_all.w's
elf_patch_load_segments, docs/projects/pie_aslr.md).

All emitted values fit in 32 bits (vaddrs live below 0x08048000+filesz and
tags/sizes are small), so emit_int64 produces identical bytes whether the
compiler itself runs as x86 or x64, keeping the self-host fixpoint intact.
*/
import code_generator.code_emitter
import code_generator.integer
import code_generator.elf_32
import code_generator.elf_64
import code_generator.dynamic_registry
import lib.lib


int sym_address(char *s);  /* from symbol_table.w */


void emit_dyn_align(int a):
	while ((codepos % a) != 0): emit_int8(0)


# Size of one symbol-table entry for the current word size.
int elf_dyn_syment():
	if (word_size == 8): return 24
	return 16


void elf_dyn_emit_sym(int name, int addr, int size, int binding, int symtype, int shndx):
	if (word_size == 8): elf_sym_table_entry_64(name, addr, size, binding, symtype, shndx)
	else: elf_sym_table_entry(name, addr, size, binding, symtype, shndx)


# One Elf32_Dyn / Elf64_Dyn entry (tag, value).
void elf_dyn_entry(int tag, int val):
	if (word_size == 8):
		emit_int64(tag)
		emit_int64(val)
	else:
		emit_int32(tag)
		emit_int32(val)


void elf_dyn_patch_phdr(int index, int type, int flags, int off, int size, int align):
	index = index + elf_pie
	int vaddr = code_offset + off
	if (word_size == 8):
		int base = phdr_table_pos + index * 56
		save_i(code + base + 0, type, 4)
		save_i(code + base + 4, flags, 4)
		save_i(code + base + 8, off, 8)
		save_i(code + base + 16, vaddr, 8)
		save_i(code + base + 24, vaddr, 8)
		save_i(code + base + 32, size, 8)
		save_i(code + base + 40, size, 8)
		save_i(code + base + 48, align, 8)
	else:
		int base = phdr_table_pos + index * 32
		save_i(code + base + 0, type, 4)
		save_i(code + base + 4, off, 4)
		save_i(code + base + 8, vaddr, 4)
		save_i(code + base + 12, vaddr, 4)
		save_i(code + base + 16, size, 4)
		save_i(code + base + 20, size, 4)
		save_i(code + base + 24, flags, 4)
		save_i(code + base + 28, align, 4)


# Android's linker validates SHT_DYNAMIC against PT_DYNAMIC and follows
# sh_link to SHT_STRTAB. Preserve the existing debug sections and append
# the dynamic section descriptions to a copied table. Old table bytes
# remain harmless padding inside the text segment.
void elf_android_section(int name, int type, int off, int size, int link, int entsize, int align):
	emit_int32(name)
	emit_int32(type)
	emit_int64(2) # SHF_ALLOC, read-only
	emit_int64(code_offset + off)
	emit_int64(off)
	emit_int64(size)
	emit_int32(link)
	int info = 0
	if (type == 11): info = 1 # first non-local .dynsym index
	emit_int32(info)
	emit_int64(align)
	emit_int64(entsize)


void elf_android_dynamic_sections(int str_off, int str_size, int sym_off, int nsym, int hash_off, int rel_off, int rel_size, int dyn_off, int dyn_size):
	int old_off = load_i(code + 40, 8)
	int count = load_i(code + 60, 2)
	int stridx = load_i(code + 62, 2)
	int table_size = count * 64
	char* table = cast(char*, malloc(table_size))
	for b in range(table_size): table[b] = code[old_off + b]
	int old_names = load_i(table + stridx * 64 + 24, 8)
	int names_size = load_i(table + stridx * 64 + 32, 8)
	char* names = cast(char*, malloc(names_size))
	for b in range(names_size): names[b] = code[old_names + b]
	int names_off = codepos
	emit(names_size, names)
	free(names)
	emit(41, c".dynstr\x00.dynsym\x00.hash\x00.rela.dyn\x00.dynamic\x00")
	save_i(table + stridx * 64 + 24, names_off, 8)
	save_i(table + stridx * 64 + 32, names_size + 41, 8)
	emit_dyn_align(8)
	int table_off = codepos
	emit(table_size, table)
	free(table)
	elf_android_section(names_size, 3, str_off, str_size, 0, 0, 1)
	elf_android_section(names_size + 8, 11, sym_off, nsym * 24, count, 24, 8)
	elf_android_section(names_size + 16, 5, hash_off, (nsym + 3) * 4, count + 1, 4, 8)
	elf_android_section(names_size + 22, 4, rel_off, rel_size, count + 1, 24, 8)
	elf_android_section(names_size + 32, 6, dyn_off, dyn_size, count, 16, 8)
	save_int64(code + 40, table_off)
	save_i(code + 60, count + 5, 2)


void elf_emit_dynamic():
	if ((dyn_has_imports() == 0) && (elf_shared == 0)): return;
	if (x64_syscall_abi): error(c"--syscall-abi=vmcall does not support dynamic imports")
	if ((dyn_lib_count == 0) && dyn_has_imports()): error(c"extern used without any c_lib to import from")

	int nexports = 0
	if (elf_shared): nexports = wasm_export_count
	int nsym = dyn_import_count + nexports + 1   /* index 0 is the reserved null symbol */
	int i

	# ---- .interp ----
	int interp_off = codepos
	if (target_os == 4): emit_string(c"/system/bin/linker64")
	else if (target_isa == 1): emit_string(c"/lib/ld-linux-aarch64.so.1")
	else if (word_size == 8): emit_string(c"/lib64/ld-linux-x86-64.so.2")
	else: emit_string(c"/lib/ld-linux.so.2")
	int interp_size = codepos - interp_off

	# ---- .dynstr (string offsets recorded for DT_NEEDED and st_name) ----
	char* lib_str_off = cast(char*, malloc(dyn_lib_count * 4 + 4))
	char* imp_str_off = cast(char*, malloc(dyn_import_count * 4 + 4))
	char* export_str_off = cast(char*, malloc(nexports * 4 + 4))
	int dynstr_off = codepos
	emit_int8(0)   /* index 0 = the empty string */
	i = 0
	while (i < dyn_lib_count):
		save_int(lib_str_off + i * 4, codepos - dynstr_off)
		emit_string(dyn_lib_name(i))
		i = i + 1
	i = 0
	while (i < dyn_import_count):
		save_int(imp_str_off + i * 4, codepos - dynstr_off)
		emit_string(dyn_import_name(i))
		i = i + 1
	for e in range(nexports):
		save_int(export_str_off + e * 4, codepos - dynstr_off)
		emit_string(cast(char*, load_i(wasm_export_names + e * __word_size__, __word_size__)))
	int soname_off = 0
	if (elf_soname != 0):
		soname_off = codepos - dynstr_off
		emit_string(elf_soname)
	int dynstr_size = codepos - dynstr_off

	# ---- .dynsym (null entry, then one symbol per import) ----
	emit_dyn_align(8)
	int dynsym_off = codepos
	emit_zeros(elf_dyn_syment())
	i = 0
	while (i < dyn_import_count):
		/* Functions: symtype 2, shndx 0 = SHN_UNDEF, no value. Weak
		   imports (bulk c_import) let headers declare functions the
		   library does not export (alloca, crypt, ...): the loader leaves
		   their GOT slots null instead of refusing to start, and only an
		   actual call through a null slot faults.

		   Data objects: symtype 1, DEFINED at the reserved copy space
		   (shndx 1 = .text, which spans the whole loaded image) with the
		   object's size, so the COPY relocation below resolves against
		   the library's definition and the library's own references
		   rebind here. */
		if (dyn_import_get_symtype(i) == 1):
			elf_dyn_emit_sym(load_int(imp_str_off + i * 4), dyn_import_got_vaddr(i), dyn_import_get_size(i), dyn_import_get_binding(i), 1, 1)
		else: elf_dyn_emit_sym(load_int(imp_str_off + i * 4), 0, 0, dyn_import_get_binding(i), 2, 0)
		i = i + 1

	for e in range(nexports):
		elf_dyn_emit_sym(load_int(export_str_off + e * 4), load_i(elf_export_addresses + e * __word_size__, __word_size__), 0, 1, 2, 1)

	# ---- SysV hash: one bucket chaining every symbol so lookups terminate ----
	emit_dyn_align(8)
	int hash_off = codepos
	emit_int32(1)       /* nbucket */
	emit_int32(nsym)    /* nchain */
	int first_symbol = 0
	if (nsym > 1): first_symbol = 1
	emit_int32(first_symbol)       /* bucket[0] -> first real symbol */
	emit_int32(0)       /* chain[0] for the null symbol */
	i = 1
	while (i < nsym):
		if (i == nsym - 1): emit_int32(0)
		else: emit_int32(i + 1)
		i = i + 1

	# ---- relocations: GLOB_DAT per function (writes its GOT slot), ----
	# ---- COPY per data object (fills its reserved copy space)      ----
	emit_dyn_align(8)
	int rel_off = codepos
	i = 0
	while (i < dyn_import_count):
		int got = dyn_import_got_vaddr(i)
		int symidx = i + 1
		int rel_type = 6            /* R_386_GLOB_DAT / R_X86_64_GLOB_DAT */
		if (dyn_import_get_symtype(i) == 1):
			rel_type = 5            /* R_386_COPY / R_X86_64_COPY */
		if (target_isa == 1):
			if (rel_type == 6):
				rel_type = 1025     /* R_AARCH64_GLOB_DAT */
			else:
				rel_type = 1024     /* R_AARCH64_COPY */
		if (word_size == 8):
			/* Elf64_Rela: r_offset, r_info=(sym<<32)|type, r_addend.
			   Emitting r_info as two dwords avoids a 64-bit shift on the
			   x86-hosted compiler. */
			emit_int64(got)
			emit_int32(rel_type)
			emit_int32(symidx)
			emit_int64(0)
		else:
			/* Elf32_Rel: r_offset, r_info=(sym<<8)|type */
			emit_int32(got)
			emit_int32((symidx << 8) + rel_type)
		i = i + 1
	# PIE data pointers: ld.so adds the load bias exactly once.
	if (elf_pie):
		for r in range(rebase_count):
			int cell = load_i(rebase_table + r * 8, 8)
			emit_int64(cell)
			if (target_isa == 1): emit_int32(1027) /* R_AARCH64_RELATIVE */
			else: emit_int32(8) /* R_X86_64_RELATIVE */
			emit_int32(0)
			emit_int64(load_i(data + cell - data_offset, 8))
	int rel_size = codepos - rel_off

	# ---- .dynamic ----
	emit_dyn_align(8)
	int dynamic_off = codepos
	i = 0
	while (i < dyn_lib_count):
		elf_dyn_entry(1, load_int(lib_str_off + i * 4))   /* DT_NEEDED */
		i = i + 1
	if (soname_off != 0): elf_dyn_entry(14, soname_off) # DT_SONAME
	elf_dyn_entry(4, code_offset + hash_off)      /* DT_HASH */
	elf_dyn_entry(5, code_offset + dynstr_off)    /* DT_STRTAB */
	elf_dyn_entry(6, code_offset + dynsym_off)    /* DT_SYMTAB */
	elf_dyn_entry(10, dynstr_size)                /* DT_STRSZ */
	elf_dyn_entry(11, elf_dyn_syment())           /* DT_SYMENT */
	if (word_size == 8):
		elf_dyn_entry(7, code_offset + rel_off)   /* DT_RELA */
		elf_dyn_entry(8, rel_size)                /* DT_RELASZ */
		elf_dyn_entry(9, 24)                       /* DT_RELAENT */
	else:
		elf_dyn_entry(17, code_offset + rel_off)  /* DT_REL */
		elf_dyn_entry(18, rel_size)               /* DT_RELSZ */
		elf_dyn_entry(19, 8)                       /* DT_RELENT */
	if (elf_pie && (elf_shared == 0)): elf_dyn_entry(1879048187, 134217728) /* DT_FLAGS_1: DF_1_PIE */
	elf_dyn_entry(0, 0)                            /* DT_NULL */
	int dynamic_size = codepos - dynamic_off
	if (target_os == 4): elf_android_dynamic_sections(dynstr_off, dynstr_size, dynsym_off, nsym, hash_off, rel_off, rel_size, dynamic_off, dynamic_size)

	free(lib_str_off)
	free(imp_str_off)
	free(export_str_off)

	# Fill the reserved program headers (both read-only). The loader
	# uses PT_DYNAMIC flags to decide whether it may adjust d_ptr in place.
	# A W^X writer (data_split) uses phdr slot 1 for its R+W data load
	# (patched after this runs), so its reserved slots are 2 and 3; a
	# single-segment image keeps slots 1 and 2.
	int interp_slot = 1
	if (data_split): interp_slot = 2
	if (elf_shared == 0): elf_dyn_patch_phdr(interp_slot, 3, 4, interp_off, interp_size, 1)
	elf_dyn_patch_phdr(interp_slot + 1, 2, 4, dynamic_off, dynamic_size, 8)

	# A dynamically linked program shares the address space with glibc,
	# whose sbrk caches the break position and never rechecks it, so a raw
	# brk from W's allocator goes unnoticed: glibc's next sbrk returns the
	# stale cached break and both allocators hand out the same memory.
	# Flip the allocator's initial mode in the image so it mmaps from the
	# first call and never touches the break.
	int mmap_mode_vaddr = sym_address(c"malloc_mmap_mode")
	if (mmap_mode_vaddr):
		if (data_split & (mmap_mode_vaddr >= data_offset)):
			save_i(data + (mmap_mode_vaddr - data_offset), 1, word_size)
		else: save_i(code + (mmap_mode_vaddr - code_offset), 1, word_size)
