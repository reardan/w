# Visit resolved global layout trees in either image storage convention.
void emit_global_storage_tree_ast(global_storage_ast* node):
	if (node.kind == 1):
		emit_target_word(code_offset + codepos + 2 * word_size)
		emit_target_word(node.length)
		emit_zeros(node.size - 2 * word_size)
	else if (node.kind == 2):
		global_storage_ast* child = node.children
		while (child):
			emit_global_storage_tree_ast(child)
			child = child.next
	else: emit_zeros(node.size)


void emit_data_storage_tree_ast(global_storage_ast* node, int address):
	if (node.kind == 1):
		save_i(data + (address - data_offset), address + 2 * word_size, word_size)
		save_i(data + (address - data_offset + word_size), node.length, word_size)
		rebase_note(address)
	else if (node.kind == 2):
		global_storage_ast* child = node.children
		while (child):
			emit_data_storage_tree_ast(child, address + child.offset)
			child = child.next


void emit_global_declaration_ast(global_declaration_ast* node):
	if (node.split):
		node.address = emit_data_zeros(node.size)
		sym_define_global_at(node.binding, node.address)
		emit_data_storage_tree_ast(node.storage, node.address)
	else:
		sym_define_global(node.binding)
		node.address = load_int(table + node.binding + 2)
		int start = codepos
		emit_global_storage_tree_ast(node.storage)
		emit_zeros(node.size - (codepos - start))
	ast_globals_emitted = ast_globals_emitted + 1


void emit_global_initializer_ast(global_declaration_ast* node):
	if (node.split): save_i(data + (node.address - data_offset), node.value, node.scalar_width)
	else: save_i(code + (node.address - code_offset), node.value, node.scalar_width)
	ast_global_initializers_emitted = ast_global_initializers_emitted + 1


void emit_thread_local_ast(global_declaration_ast* node):
	if (tls_size == 0): tls_size = word_size
	node.address = tls_size
	tls_size = tls_size + node.size
	sym_define_global_at(node.binding, node.address)
	sym_set_thread_local(node.binding)
	ast_thread_locals_emitted = ast_thread_locals_emitted + 1
