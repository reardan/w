/*
Dynamic-linking sections for executables that import shared libraries via
c_lib / extern. Everything is appended to the single PT_LOAD segment at
finish time and the reserved PT_INTERP / PT_DYNAMIC program headers are
patched to point at it.

Binding is eager: one GOT slot per import (emitted inline next to its shim)
plus one GLOB_DAT relocation, so the loader writes the resolved address
before the entry point runs -- no PLT, no lazy resolver.

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


void emit_dyn_align(int a):
	while ((codepos % a) != 0):
		emit_int8(0)


# Size of one symbol-table entry for the current word size.
int elf_dyn_syment():
	if (word_size == 8):
		return 24
	return 16


void elf_dyn_emit_sym(int name, int addr, int size, int binding, int symtype, int shndx):
	if (word_size == 8):
		elf_sym_table_entry_64(name, addr, size, binding, symtype, shndx)
	else:
		elf_sym_table_entry(name, addr, size, binding, symtype, shndx)


# One Elf32_Dyn / Elf64_Dyn entry (tag, value).
void elf_dyn_entry(int tag, int val):
	if (word_size == 8):
		emit_int64(tag)
		emit_int64(val)
	else:
		emit_int32(tag)
		emit_int32(val)


void elf_dyn_patch_phdr(int index, int type, int flags, int off, int size, int align):
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


void elf_emit_dynamic():
	if (dyn_has_imports() == 0):
		return;
	if (dyn_lib_count == 0):
		error(c"extern used without any c_lib to import from")

	int nsym = dyn_import_count + 1   /* index 0 is the reserved null symbol */
	int i

	# ---- .interp ----
	int interp_off = codepos
	if (word_size == 8):
		emit_string(c"/lib64/ld-linux-x86-64.so.2")
	else:
		emit_string(c"/lib/ld-linux.so.2")
	int interp_size = codepos - interp_off

	# ---- .dynstr (string offsets recorded for DT_NEEDED and st_name) ----
	int lib_str_off = malloc(dyn_lib_count * 4 + 4)
	int imp_str_off = malloc(dyn_import_count * 4 + 4)
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
	int dynstr_size = codepos - dynstr_off

	# ---- .dynsym (null entry, then one undefined func per import) ----
	emit_dyn_align(8)
	int dynsym_off = codepos
	emit_zeros(elf_dyn_syment())
	i = 0
	while (i < dyn_import_count):
		/* binding 1 = global, symtype 2 = func, shndx 0 = SHN_UNDEF */
		elf_dyn_emit_sym(load_int(imp_str_off + i * 4), 0, 0, 1, 2, 0)
		i = i + 1

	# ---- SysV hash: one bucket chaining every symbol so lookups terminate ----
	emit_dyn_align(8)
	int hash_off = codepos
	emit_int32(1)       /* nbucket */
	emit_int32(nsym)    /* nchain */
	emit_int32(1)       /* bucket[0] -> first real symbol */
	emit_int32(0)       /* chain[0] for the null symbol */
	i = 1
	while (i < nsym):
		if (i == nsym - 1):
			emit_int32(0)
		else:
			emit_int32(i + 1)
		i = i + 1

	# ---- relocations: one GLOB_DAT per import, writing its GOT slot ----
	emit_dyn_align(8)
	int rel_off = codepos
	i = 0
	while (i < dyn_import_count):
		int got = dyn_import_got_vaddr(i)
		int symidx = i + 1
		if (word_size == 8):
			/* Elf64_Rela: r_offset, r_info=(sym<<32)|type, r_addend.
			   Emitting r_info as two dwords avoids a 64-bit shift on the
			   x86-hosted compiler. */
			emit_int64(got)
			emit_int32(6)        /* R_X86_64_GLOB_DAT */
			emit_int32(symidx)
			emit_int64(0)
		else:
			/* Elf32_Rel: r_offset, r_info=(sym<<8)|type */
			emit_int32(got)
			emit_int32((symidx << 8) + 6)   /* R_386_GLOB_DAT */
		i = i + 1
	int rel_size = codepos - rel_off

	# ---- .dynamic ----
	emit_dyn_align(8)
	int dynamic_off = codepos
	i = 0
	while (i < dyn_lib_count):
		elf_dyn_entry(1, load_int(lib_str_off + i * 4))   /* DT_NEEDED */
		i = i + 1
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
	elf_dyn_entry(0, 0)                            /* DT_NULL */
	int dynamic_size = codepos - dynamic_off

	free(lib_str_off)
	free(imp_str_off)

	# Fill the reserved program headers (PT_INTERP = R, PT_DYNAMIC = R+W).
	elf_dyn_patch_phdr(1, 3, 4, interp_off, interp_size, 1)
	elf_dyn_patch_phdr(2, 2, 6, dynamic_off, dynamic_size, 8)
