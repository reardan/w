# Image setup shared by the executable writers (elf_all.w's ELF headers,
# macho_64.w, pe_64.w, wasm_module.w). Kept out of code_emitter.w, which
# standalone tools import without the compiler's symbol table.
import code_generator.code_emitter


int sym_address(char *s);  /* compiler/symbol_table.w */


# Image layout shared by the file writers: code and symbols linked at
# base, and the read-write data segment 16 MB above it, clear of the code
# and section tables (~1.5 MB). Mutable globals, GOT/IAT slots and
# extern-data copy space are emitted there (data_split) at
# data_offset + datapos.
void image_begin(int base):
	base_code_offset = base
	code_offset = base
	data_offset = base + 16777216 /* +0x1000000 */
	datapos = 0
	data_size = 4096
	data = malloc(data_size)


# The program's entry function: runtime_start (a target's runtime
# startup, which chains to _main) when given and _main exists, else
# _main (lib.lib's), else main. 0 only for a main-less library module
# under 'w check' (entry_optional), where the entry stays unpatched: the
# output is discarded.
int entry_symbol(char* runtime_start):
	int t = 0
	if ((runtime_start != 0) && (sym_address(c"_main") != 0)): t = sym_address(runtime_start)
	if (t == 0): t = sym_address(c"_main")
	if (t == 0): t = sym_address(c"main")
	if ((t == 0) && (entry_optional == 0)):
		error(c"Failed to find a _main() function. Did you import lib/testing?")
	return t
