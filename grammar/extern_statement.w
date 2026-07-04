/*
Top-level declarations for calling shared-library functions:

	c_lib "libc.so.6"
	extern int printf(char* fmt)

c_lib records a DT_NEEDED soname. extern declares a callable function whose
address is a generated ABI shim (see code_generator/ffi.w): callers use it
like any W function, the shim converts the arguments to the platform C ABI
and jumps through a GOT slot the dynamic loader fills in at load time.
*/
import grammar.type_name
import grammar.string_literal
import code_generator.dynamic_registry
import code_generator.ffi


int extern_statement():
	if (accept(c"c_lib")):
		if ((token[0] != '"') & (((token[0] != 'c') | (token[1] != '"')))):
			error(c"c_lib expects a \"soname\" string literal")
		int len
		if (token[0] == 'c'):
			len = process_prefixed_string_literal()
		else:
			len = process_string_literal()
		token[len] = 0
		dyn_add_lib(token)
		get_token()
		return 1

	if (accept(c"extern")):
		# type_name() consumes the return type and leaves the name in token
		int ret_type = type_name()
		char* name = strclone(token)
		int sym = sym_declare_global(name, ret_type, 2)  /* function symbol */
		get_token()
		expect(c"(")

		# Parse the parameter list for arity/type checks. Count stack words
		# (one per scalar/pointer arg); struct-by-value params are not
		# supported across the C boundary.
		int saved_table = table_pos
		int param_count = 0
		while (accept(c")") == 0):
			param_count = param_count + 1
			int ptype = type_name()
			if (param_count <= sym_max_param_slots()):
				save_int(table + sym + 22 + (param_count << 2), ptype)
			# Skip the optional parameter name
			if (peek(c")") == 0):
				get_token()
			accept(c",")
		# Parameters need no symbols of their own (no body is emitted)
		table_pos = saved_table
		save_int(table + sym + 22, param_count)

		# GOT slot the loader relocates, emitted just before the shim so its
		# vaddr is known now; execution enters at the shim, never the slot.
		int got_vaddr = code_offset + codepos
		emit_zeros(word_size)
		dyn_add_import(name, got_vaddr)

		# The symbol resolves to the shim entry point
		sym_define_global(sym)
		emit_ffi_shim(param_count, got_vaddr)

		free(name)
		return 1

	return 0
