# wasm register context: the wasm target has no capturable register file
# (locals and the operand stack are not addressable) and runtime stack
# traces are skipped (no symtab/DWARF in the module, and the return-slot
# words on the W stack hold no code addresses), so this module only keeps
# lib/lib.w's context import compiling. The struct mirrors the W-visible
# state: the shadow-stack pointer.

struct register_context:
	int sp


void print_stack():
	println2(c"Stack: (not available on the wasm target)")


void print_registers():
	println2(c"Registers: (not available on the wasm target)")
