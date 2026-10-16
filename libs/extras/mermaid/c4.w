# C4 context/container/component/dynamic/deployment semantic cards and boundaries.
import libs.extras.mermaid.frameworks

list[char*] mm_c4_arguments(mm_parser* p):
	list[char*] args = new list[char*]
	mm_space(p)
	if (mm_match(p, c"(") == 0): mm_error(p.doc, p.pos, c"expected C4 argument list")
	while (p.doc.error == 0):
		mm_space(p)
		if (mm_peek(p) == ')'):
			p.pos = p.pos + 1
			return args
		if (args.length >= 6):
			mm_error(p.doc, p.pos, c"too many C4 arguments")
			break
		char* value
		if (mm_peek(p) == '"'): value = mm_quoted(p)
		else:
			int start = p.pos
			while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != ',' && mm_peek(p) != ')'): p.pos = p.pos + 1
			int end = p.pos
			while (end > start && p.doc.source[end - 1] == 32): end = end - 1
			value = str_copy_range(p.doc.source, start, end)
			if (index_of(value, c"=") >= 0): mm_error(p.doc, start, c"named C4 configuration arguments are unsupported")
		if (value[0] == 0): mm_error(p.doc, p.pos, c"expected nonempty C4 argument")
		args.push(value)
		mm_space(p)
		if (mm_match(p, c",") == 0):
			if (mm_match(p, c")") == 0): mm_error(p.doc, p.pos, c"expected C4 argument closing parenthesis")
			return args
	return args

void mm_c4_body(mm_parser* p, int scope, int depth):
	if (depth >= 32):
		mm_error(p.doc, p.pos, c"C4 boundary nesting limit exceeded")
		return
	while (mm_peek(p) != 0 && p.doc.error == 0):
		if (mm_metadata(p)):
			mm_separators(p)
			continue
		if (mm_match(p, c"}")):
			if (scope < 0): mm_error(p.doc, p.pos, c"unexpected C4 closing boundary")
			return
		char* function = mm_identifier(p)
		if (strcmp(function, c"title") == 0):
			free(p.doc.title)
			p.doc.title = mm_line_text(p)
			free(function)
			mm_separators(p)
			continue
		list[char*] args = mm_c4_arguments(p)
		int group = mm_in_words(function, c"|Boundary|Enterprise_Boundary|System_Boundary|Container_Boundary|Deployment_Node|Node|Node_L|Node_R|")
		int node = group || mm_in_words(function, c"|Person|Person_Ext|System|System_Ext|SystemDb|SystemDb_Ext|SystemQueue|SystemQueue_Ext|Container|Container_Ext|ContainerDb|ContainerDb_Ext|ContainerQueue|ContainerQueue_Ext|Component|Component_Ext|ComponentDb|ComponentDb_Ext|ComponentQueue|ComponentQueue_Ext|")
		int relationship = mm_in_words(function, c"|Rel|BiRel|Rel_Back|")
		if (node):
			if (args.length < 2 || args.length > 4): mm_error(p.doc, p.pos, c"C4 node expects id, label and optional technology/description")
			if (p.doc.error == 0):
				int index = mm_add_node(p.doc, args[0], p.pos)
				if (index >= 0):
					mm_node* n = p.doc.nodes[index]
					if (n.declared): mm_error(p.doc, p.pos, c"duplicate C4 node")
					if (index == scope): mm_error(p.doc, p.pos, c"cyclic C4 boundary")
					n.declared = 1
					n.parent = scope
					n.group = group
					free(n.label)
					n.label = strclone(args[1])
					free(n.annotation)
					n.annotation = strclone(function)
					for i in range(2, args.length): mm_graph_member(p, n, c"detail", args[i])
					if (group):
						if (args.length > 2):
							string_builder* label = string_from(n.label)
							for i in range(2, args.length):
								string_append(label, c" / ")
								string_append(label, args[i])
							free(n.label)
							n.label = strclone(label.data)
							string_free(label)
						mm_space(p)
						if (mm_match(p, c"{") == 0): mm_error(p.doc, p.pos, c"expected C4 boundary block")
						mm_separators(p)
						if (p.doc.error == 0): mm_c4_body(p, index, depth + 1)
		else if (relationship):
			if (args.length < 3 || args.length > 4): mm_error(p.doc, p.pos, c"C4 relation expects source, target, label and optional technology")
			if (p.doc.edges.length >= MM_MAX_ITEMS): mm_error(p.doc, p.pos, c"C4 relationship limit exceeded")
			if (p.doc.error == 0):
				int from = mm_add_node(p.doc, args[0], p.pos)
				int to = mm_add_node(p.doc, args[1], p.pos)
				if (p.doc.error == 0):
					mm_edge* e = new mm_edge()
					e.from_node = from
					e.to_node = to
					if (strcmp(function, c"Rel_Back") == 0):
						e.from_node = to
						e.to_node = from
					e.right_marker = MM_ARROW
					if (strcmp(function, c"BiRel") == 0): e.left_marker = MM_ARROW
					e.left_label = strclone(c"")
					e.right_label = strclone(c"")
					e.scope = -1
					string_builder* label = string_new()
					if (p.doc.graph_variant == 3):
						string_append_int(label, p.doc.edges.length + 1)
						string_append(label, c": ")
					string_append(label, args[2])
					if (args.length > 3):
						string_append(label, c" [")
						string_append(label, args[3])
						string_append_char(label, ']')
					e.label = strclone(label.data)
					string_free(label)
					p.doc.edges.push(e)
		else: mm_error(p.doc, p.pos, c"unsupported C4 declaration or configuration")
		for char* value in args: free(value)
		__w_list_free(cast(__w_list*, args))
		free(function)
		if (mm_end(p) == 0 && mm_peek(p) != '}'): mm_error(p.doc, p.pos, c"expected C4 statement separator")
		mm_separators(p)
	if (scope >= 0 && p.doc.error == 0): mm_error(p.doc, p.pos, c"unterminated C4 boundary")
	if (scope < 0):
		for mm_node* n in p.doc.nodes:
			if (n.declared == 0): mm_error(p.doc, p.pos, c"C4 relation references undeclared node")
