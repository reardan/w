# Register the extern data object sym whose size bytes of space start at
# address. In an object (--emit=obj) an extern fixed array is a C array,
# with no {data, length} header in front of its elements: W keeps the
# header in its own data, pointing at the imported elements, so W code
# indexes the array as usual.
void extern_object_import(int sym, int address, int size, char* name):
	int type = type_canonical(load_int(table + sym + 6))
	int header = 0
	if (elf_object && data_split && type_is_array(type)):
		if (type_has_array_field(type_get_element_type(type))):
			error3(c"extern array '", name, c"' needs elements without nested array headers")
		header = 2 * word_size
		emit_data_global_storage(type, address)
	dyn_add_import_data(name, address + header, size - header, 0)


# 'extern T[] name' in an object: a C array of unknown length (C's
# 'extern T name[];'). The name is a T* holding the C symbol's address
# (a pointer cell in .data relocated against the undefined symbol, not a
# symbol of its own), so indexing it is unchecked pointer indexing and
# its value is the array's address, as in C.
void extern_unsized_array(int sym, int element_type, char* name):
	if ((elf_object == 0) || (data_split == 0)):
		error3(c"extern array '", name, c"' has no length: an unsized extern array needs --emit=obj")
	if (type_has_array_field(element_type)):
		error3(c"extern array '", name, c"' needs elements without nested array headers")
	save_int(table + sym + 6, type_get_next_pointer(element_type))
	save_int(table + sym + 10, 1)   /* symtype: object */
	int pad = datapos & (word_size - 1)
	if (pad != 0): emit_data_zeros(word_size - pad)
	int cell = emit_data_zeros(word_size)
	int size = type_get_size(element_type)
	if (size < 1): size = 1
	# placeholder space the import names; the cell points at it
	int space = emit_data_zeros(((size + word_size - 1) >> word_size_log2) << word_size_log2)
	save_i(data + (cell - data_offset), space, word_size)
	rebase_note(cell)
	sym_define_global_at(sym, cell)
	save_int(table + sym + 14, word_size)
	object_note_extern_pointer(sym)
	dyn_add_import_data(name, space, size, 0)


# Emit bytes and relocation/import metadata from resolved declarations.
void emit_linkage_ast(linkage_ast* node):
	if (node.kind == ast_linkage_enum):
		if (node.split):
			sym_define_global_at(node.binding, data_offset + datapos)
			emit_data_word(node.value)
		else:
			sym_define_global(node.binding)
			emit_int32(node.value)
		ast_enum_values_emitted = ast_enum_values_emitted + 1
		return
	if (node.kind == ast_linkage_object):
		if (node.split):
			int pad = datapos & (word_size - 1)
			if (pad != 0): emit_data_zeros(word_size - pad)
			int address = emit_data_zeros(node.size)
			sym_define_global_at(node.binding, address)
			save_int(table + node.binding + 14, node.size)
			extern_object_import(node.binding, address, node.size, node.name)
		else:
			while ((codepos % word_size) != 0): emit_int8(0)
			sym_define_global(node.binding)
			save_int(table + node.binding + 14, node.size)
			dyn_add_import_data(node.name, code_offset + codepos, node.size, 0)
			emit_zeros(node.size)
		ast_extern_objects_emitted = ast_extern_objects_emitted + 1
		return
	if (node.kind == ast_linkage_wasm):
		int index = wasm_extern_add(node.module_name, node.import_name, node.parameter_count, node.parameter_classes, node.return_kind)
		wasm_extern_stub(node.binding, node.name, index, node.parameter_count, node.parameter_classes, node.return_kind)
	else:
		int address = static_link_import_slot(node.import_name)
		be_align_code()
		sym_define_global(node.binding)
		c_abi_emit_extern_shim(node.binding, node.parameter_count, node.parameter_classes, node.return_class, address)
		# Every import records its slot: the variadic call path loads
		# through it, and tools/wllvm_emit.w finds the import by it.
		sym_set_got_vaddr(node.binding, address)
		if (node.variadic): sym_set_variadic(node.binding, node.parameter_count)
	ast_extern_functions_emitted = ast_extern_functions_emitted + 1
