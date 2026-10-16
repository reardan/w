# Agentflow's semantic roles and scalar metadata; no connector is executed.
import libs.extras.mermaid.parse_common

void mm_agent_shape(mm_parser* p, mm_node* n, char* value):
	if (n.group):
		mm_error(p.doc, p.pos, c"agentflow container shape overrides are not supported")
		return
	if (strcmp(value, c"task") == 0 || strcmp(value, c"roundedRect") == 0): n.shape = 1
	else if (strcmp(value, c"tool") == 0 || strcmp(value, c"subroutine") == 0): n.shape = 17
	else if (strcmp(value, c"input") == 0 || strcmp(value, c"lean-right") == 0): n.shape = 18
	else if (strcmp(value, c"decision") == 0 || strcmp(value, c"diamond") == 0): n.shape = 3
	else if (strcmp(value, c"refdoc") == 0 || strcmp(value, c"lin-doc") == 0): n.shape = 19
	else if (strcmp(value, c"action") == 0 || strcmp(value, c"hexagon") == 0): n.shape = 20
	else if (strcmp(value, c"rect") == 0 || strcmp(value, c"rectangle") == 0): n.shape = 0
	else if (strcmp(value, c"circle") == 0): n.shape = 2
	else: mm_error(p.doc, p.pos, c"unsupported agentflow shape")
	free(n.role)
	n.role = strclone(value)

void mm_agent_metadata(mm_parser* p, mm_node* n):
	mm_space(p)
	if (mm_match(p, c"@{") == 0): return
	while (p.doc.error == 0):
		mm_space(p)
		while (mm_peek(p) == 10):
			p.pos = p.pos + 1
			mm_space(p)
		if (mm_match(p, c"}")): return
		char* key = mm_identifier(p)
		mm_space(p)
		if (mm_match(p, c":") == 0): mm_error(p.doc, p.pos, c"expected colon after metadata key")
		mm_space(p)
		char* value
		if (mm_peek(p) == '"'): value = mm_quoted(p)
		else:
			int start = p.pos
			while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != ',' && mm_peek(p) != '}'):
				if (mm_peek(p) == '{' || mm_peek(p) == '['): mm_error(p.doc, p.pos, c"structured YAML metadata is not yet supported")
				p.pos = p.pos + 1
			int end = p.pos
			while (end > start && (p.doc.source[end - 1] & 255) <= 32): end = end - 1
			value = str_copy_range(p.doc.source, start, end)
			if (value[0] == 0): mm_error(p.doc, start, c"expected metadata value")
		int found = 0
		for mm_property* property in n.metadata:
			if (strcmp(property.key, key) == 0):
				free(property.value)
				property.value = strclone(value)
				found = 1
		int reserved = strcmp(key, c"__proto__") == 0 || strcmp(key, c"constructor") == 0 || strcmp(key, c"prototype") == 0
		if (found == 0 && reserved == 0):
			if (n.metadata.length >= 64): mm_error(p.doc, p.pos, c"agentflow metadata limit exceeded (64 per node)")
			else: n.metadata.push(new mm_property(strclone(key), strclone(value)))
		if (strcmp(key, c"shape") == 0): mm_agent_shape(p, n, value)
		else if (strcmp(key, c"label") == 0):
			free(n.label)
			n.label = strclone(value)
		else if (strcmp(key, c"view") == 0 || strcmp(key, c"algorithm") == 0 || strcmp(key, c"curve") == 0 || strcmp(key, c"animate") == 0 || strcmp(key, c"animation") == 0): mm_error(p.doc, p.pos, c"unsupported agentflow presentation metadata")
		else if (strcmp(key, c"labelType") == 0 && strcmp(value, c"text") != 0): mm_error(p.doc, p.pos, c"only text agentflow labels are supported")
		free(key)
		free(value)
		mm_space(p)
		if (mm_match(p, c"}")): return
		if (mm_match(p, c",")): continue
		if (mm_peek(p) != 10): mm_error(p.doc, p.pos, c"expected comma, newline or closing metadata brace")
