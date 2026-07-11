/*
Top-level declarations for using shared-library symbols:

	c_lib "libc.so.6"
	extern int puts(char* s)
	extern int printf(char* fmt, ...)
	extern void* stdout

c_lib records a DT_NEEDED soname. extern declares a callable function whose
address is a generated ABI shim (see code_generator/ffi.w): callers use it
like any W function, the shim converts the arguments to the platform C ABI
and jumps through a GOT slot the dynamic loader fills in at load time.

A trailing '...' declares a variadic C function: direct calls accept any
number of extra arguments and emit the ABI conversion inline per call
site (grammar/postfix_expr.w), applying the C default argument promotions.

An '= "symbol"' suffix binds a library symbol under a different W name:

	extern int objc_msg1(void* recv, void* sel, int a) = "objc_msgSend"

so one C symbol can be declared once per call signature.

extern without a parameter list imports a data object: the loader fills
reserved space in the image via a COPY relocation and the symbol behaves
like a normal W global.

On the wasm target there are no shared libraries: c_lib names a wasm
import module instead ("env" when absent) and each extern becomes a typed
entry in the module's import section, bound by the embedding host at
instantiation (docs/projects/wasm_webgl.md). Variadic and data imports
have no wasm equivalent and are rejected.
*/
import grammar.type_name
import grammar.string_literal
import code_generator.dynamic_registry
import code_generator.ffi


int extern_max_params():
	return 255


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

		# No parameter list: an imported data object (e.g. extern void*
		# stdout). Space for the object is reserved in the image and a COPY
		# relocation makes the loader fill it with the library's initial
		# value; the library's own references rebind to this copy (symbol
		# interposition), so it behaves like a normal W global.
		if (accept(c"(") == 0):
			# The copy space below is reserved in the code stream, which
			# W^X arm64 targets map read-execute — the loader's COPY write
			# would fault. Needs a data-segment home before enabling.
			if (target_isa == 1):
				error(c"extern data objects are not supported on arm64 targets yet")
			# wasm has no loader and no COPY relocations; imported globals
			# exist but nothing in lib/ needs them.
			if (target_isa == 2):
				error(c"extern data objects are not supported on the wasm target")
			save_int(table + sym + 10, 1)   /* symtype: object */
			int size = type_get_size(ret_type)
			if (size < 1):
				error(c"extern data object needs a sized type")
			while ((codepos % word_size) != 0):
				emit_int8(0)
			sym_define_global(sym)
			save_int(table + sym + 14, size)
			dyn_add_import_data(name, code_offset + codepos, size, 0)
			emit_zeros(size)
			free(name)
			return 1

		# Parse the parameter list for arity/type checks and the ABI shim's
		# argument classes. Struct-by-value params are not supported across
		# the C boundary.
		int saved_table = table_pos
		int param_count = 0
		int is_variadic = 0
		char* param_classes = malloc(extern_max_params())
		int ret_class = ffi_type_class(ret_type)
		if ((ret_class == 2) & (word_size != 8)):
			error(c"float64 requires the x64 target")
		while (accept(c")") == 0):
			# A trailing '...' marks a variadic C function: calls may pass
			# any number of extra arguments after the fixed ones.
			if (accept(c".")):
				expect(c".")
				expect(c".")
				is_variadic = 1
				expect(c")")
				break
			param_count = param_count + 1
			if (param_count > extern_max_params()):
				error(c"too many extern parameters")
			int ptype = type_name()
			int ptype_class = ffi_type_class(ptype)
			if ((ptype_class == 2) & (word_size != 8)):
				error(c"float64 requires the x64 target")
			param_classes[param_count - 1] = ptype_class
			if (param_count <= sym_max_param_slots()):
				save_int(table + sym + 22 + (param_count << 2), ptype)
			# Skip the optional parameter name
			if (peek(c")") == 0):
				get_token()
			accept(c",")
		# Parameters need no symbols of their own (no body is emitted)
		table_pos = saved_table
		save_int(table + sym + 22, param_count)

		# Optional '= "symbol"' alias: the loader binds import_name while
		# W code calls the declared name, so one library symbol can be
		# declared once per call signature (e.g. objc_msgSend).
		char* import_name = name
		if (accept(c"=")):
			if ((token[0] != '"') & (((token[0] != 'c') | (token[1] != '"')))):
				error(c"extern alias expects a \"symbol\" string literal")
			int alias_len
			if (token[0] == 'c'):
				alias_len = process_prefixed_string_literal()
			else:
				alias_len = process_string_literal()
			token[alias_len] = 0
			import_name = strclone(token)
			get_token()

		# wasm: no GOT slot and no ABI shim — the import arrives through
		# the module's import section with a real typed signature, wrapped
		# by a W-callable stub (wasm_extern_stub). The enclosing c_lib
		# string names the import module, "env" when none was declared;
		# the host (tools/web/) supplies the functions at instantiation.
		if (target_isa == 2):
			if (is_variadic):
				error(c"variadic extern functions are not supported on the wasm target")
			int ret_kind = 1
			if (ret_class == 1):
				ret_kind = 2
			if (type_get_pointer_level(ret_type) == 0):
				if (strcmp(type_get_name(ret_type), c"void") == 0):
					ret_kind = 0
			char* module_name = c"env"
			if (dyn_lib_count > 0):
				module_name = dyn_lib_name(dyn_lib_count - 1)
			int funcidx = wasm_extern_add(module_name, import_name, param_count, param_classes, ret_kind)
			wasm_extern_stub(sym, name, funcidx, param_count, param_classes, ret_kind)
		else:
			# GOT slot the loader relocates (one-entry IAT on win64),
			# emitted just before the shim so its vaddr is known now;
			# execution enters at the shim, never the slot.
			int got_vaddr = dyn_emit_import_slot()
			dyn_add_import(import_name, got_vaddr)

			# The symbol resolves to the shim entry point. For a variadic
			# function the shim only covers calls that pass exactly the
			# fixed parameters (e.g. through a function pointer); direct
			# calls emit the C ABI conversion inline for the actual
			# argument classes (see parse_variadic_call_suffix).
			be_align_code()
			sym_define_global(sym)
			emit_ffi_shim(param_count, param_classes, ret_class, got_vaddr)
			if (is_variadic):
				sym_set_variadic(sym, param_count)
				sym_set_got_vaddr(sym, got_vaddr)

		free(param_classes)
		if (import_name != name):
			free(import_name)
		free(name)
		return 1

	return 0
