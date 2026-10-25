# C4 context/container/component/dynamic/deployment semantic cards and boundaries.
#
# Calls follow the upstream C4-PlantUML-compatible signatures: positional
# arguments bind in signature order and `$name=value` arguments bind by name.
# Semantic fields beyond the alias and label are kept as node metadata
# (techn, descr, type, sprite, tags, link).
import libs.extras.mermaid.frameworks
import libs.extras.mermaid.style

const int MM_C4_MAX_ARGUMENTS = 12

# Parsed call arguments: names[i] is "" for a positional argument.
struct mm_c4_call:
	list[char*] names
	list[char*] values

void mm_c4_call_free(mm_c4_call* call):
	for char* name in call.names: free(name)
	for char* value in call.values: free(value)
	__w_list_free(cast(__w_list*, call.names))
	__w_list_free(cast(__w_list*, call.values))
	free(call)

char* mm_c4_value(mm_parser* p):
	mm_space(p)
	if (mm_peek(p) == '"'): return mm_quoted(p)
	int start = p.pos
	while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != ',' && mm_peek(p) != ')'): p.pos = p.pos + 1
	return mm_style_trim(p.doc.source, start, p.pos)

mm_c4_call* mm_c4_arguments(mm_parser* p):
	mm_c4_call* call = new mm_c4_call()
	call.names = new list[char*]
	call.values = new list[char*]
	mm_space(p)
	if (mm_match(p, c"(") == 0):
		mm_error(p.doc, p.pos, c"expected C4 argument list")
		return call
	mm_space(p)
	if (mm_match(p, c")")): return call
	while (p.doc.error == 0):
		mm_space(p)
		if (call.values.length >= MM_C4_MAX_ARGUMENTS):
			mm_error(p.doc, p.pos, c"too many C4 arguments")
			break
		char* name = strclone(c"")
		int start = p.pos
		if (mm_match(p, c"$")):
			int name_start = p.pos
			while (mm_id_char(mm_peek(p))): p.pos = p.pos + 1
			free(name)
			name = str_copy_range(p.doc.source, name_start, p.pos)
			mm_space(p)
			if (name[0] == 0 || mm_match(p, c"=") == 0): mm_error(p.doc, start, c"expected C4 named argument $name=value")
		int quoted = mm_peek(p) == '"'
		char* value = mm_c4_value(p)
		if (name[0] == 0 && quoted == 0 && index_of(value, c"=") >= 0): mm_error(p.doc, start, c"C4 named arguments start with $")
		call.names.push(name)
		call.values.push(value)
		mm_space(p)
		if (mm_match(p, c",") == 0):
			if (mm_match(p, c")") == 0): mm_error(p.doc, p.pos, c"expected C4 argument closing parenthesis")
			return call
	return call

# Index of name in a "|a|b|c|" signature, or -1.
int mm_c4_param(char* signature, char* name):
	int index = 0
	int start = 1
	int length = strlen(signature)
	for i in range(1, length):
		if (signature[i] == '|'):
			int n = i - start
			if (n == strlen(name)):
				int same = 1
				for j in range(n):
					if (signature[start + j] != name[j]): same = 0
				if (same): return index
			index = index + 1
			start = i + 1
	return -1

# Owned name of parameter index in a "|a|b|c|" signature.
char* mm_c4_param_name(char* signature, int index):
	int start = 1
	int count = 0
	for i in range(1, strlen(signature)):
		if (signature[i] == '|'):
			if (count == index): return str_copy_range(signature, start, i)
			count = count + 1
			start = i + 1
	return strclone(c"")

# Decimal integer in [low, high], or -1.
int mm_c4_int(char* value, int low, int high):
	int length = strlen(value)
	if (length == 0 || length > 4): return -1
	int result = 0
	for i in range(length):
		if (value[i] < '0' || value[i] > '9'): return -1
		result = result * 10 + value[i] - '0'
	if (result < low || result > high): return -1
	return result

int mm_c4_param_count(char* signature):
	int count = 0
	for i in range(1, strlen(signature)):
		if (signature[i] == '|'): count = count + 1
	return count

# Binds a call to its signature. Missing parameters are null; at least
# `required` leading parameters must be present and nonempty.
list[char*] mm_c4_bind(mm_parser* p, mm_c4_call* call, char* signature, int required, int offset):
	int count = mm_c4_param_count(signature)
	list[char*] bound = new list[char*]
	for i in range(count): bound.push(0)
	int positional = 0
	for i in range(call.values.length):
		int index = positional
		char* name = call.names[i]
		if (name[0] != 0):
			index = mm_c4_param(signature, name)
			if (index < 0):
				mm_error(p.doc, offset, c"unknown C4 named argument")
				break
		else:
			positional = positional + 1
			if (index >= count):
				mm_error(p.doc, offset, c"too many C4 arguments")
				break
		if (bound[index] != 0):
			mm_error(p.doc, offset, c"duplicate C4 argument")
			break
		bound[index] = strclone(call.values[i])
	for i in range(required):
		if (p.doc.error == 0 && (bound[i] == 0 || bound[i][0] == 0)): mm_error(p.doc, offset, c"missing required C4 argument")
	return bound

void mm_c4_bound_free(list[char*] bound):
	for char* value in bound:
		if (value != 0): free(value)
	__w_list_free(cast(__w_list*, bound))

char* mm_c4_get(mm_node* n, char* key):
	for mm_property* property in n.metadata:
		if (strcmp(property.key, key) == 0): return property.value
	return 0

void mm_c4_set(mm_node* n, char* key, char* value):
	for mm_property* property in n.metadata:
		if (strcmp(property.key, key) == 0):
			free(property.value)
			property.value = strclone(value)
			return
	n.metadata.push(new mm_property(strclone(key), strclone(value)))

# Signed pixel offset within +-2000, or the sentinel 1000000 when malformed.
int mm_c4_offset(char* text):
	int i = 0
	int sign = 1
	if (text[0] == '-'):
		sign = -1
		i = 1
	else if (text[0] == '+'): i = 1
	if (text[i] == 0): return 1000000
	int value = 0
	while (text[i] != 0):
		if (text[i] < '0' || text[i] > '9' || value > 2000): return 1000000
		value = value * 10 + text[i] - '0'
		i = i + 1
	if (value > 2000): return 1000000
	return value * sign

int mm_c4_color(mm_parser* p, char* value, int offset):
	int color = mm_style_css_color(value)
	if (color == -2): mm_error(p.doc, offset, c"invalid C4 style color")
	return color

char* mm_c4_signature(char* function):
	if (mm_in_words(function, c"|Person|Person_Ext|System|System_Ext|SystemDb|SystemDb_Ext|SystemQueue|SystemQueue_Ext|")): return c"|alias|label|descr|sprite|tags|link|"
	if (mm_in_words(function, c"|Container|Container_Ext|ContainerDb|ContainerDb_Ext|ContainerQueue|ContainerQueue_Ext|Component|Component_Ext|ComponentDb|ComponentDb_Ext|ComponentQueue|ComponentQueue_Ext|")): return c"|alias|label|techn|descr|sprite|tags|link|"
	if (strcmp(function, c"Boundary") == 0): return c"|alias|label|type|tags|link|"
	if (mm_in_words(function, c"|Enterprise_Boundary|System_Boundary|Container_Boundary|")): return c"|alias|label|tags|link|"
	if (mm_in_words(function, c"|Deployment_Node|Node|Node_L|Node_R|")): return c"|alias|label|type|descr|sprite|tags|link|"
	if (strcmp(function, c"RelIndex") == 0): return c"|index|from|to|label|techn|descr|sprite|tags|link|"
	if (mm_in_words(function, c"|Rel|BiRel|Rel_Back|Rel_U|Rel_Up|Rel_D|Rel_Down|Rel_L|Rel_Left|Rel_R|Rel_Right|BiRel_U|BiRel_Up|BiRel_D|BiRel_Down|BiRel_L|BiRel_Left|BiRel_R|BiRel_Right|")): return c"|from|to|label|techn|descr|sprite|tags|link|"
	if (strcmp(function, c"UpdateElementStyle") == 0 || strcmp(function, c"updateElementStyle") == 0): return c"|elementName|bgColor|fontColor|borderColor|shadowing|shape|sprite|techn|legendText|legendSprite|"
	if (strcmp(function, c"UpdateRelStyle") == 0 || strcmp(function, c"updateRelStyle") == 0): return c"|from|to|textColor|lineColor|offsetX|offsetY|"
	if (strcmp(function, c"UpdateLayoutConfig") == 0 || strcmp(function, c"updateLayoutConfig") == 0): return c"|c4ShapeInRow|c4BoundaryInRow|"
	return 0

# Directional macros route the relation between the named sides:
# ports are 1 left, 2 right, 3 top, 4 bottom (shared with architecture).
void mm_c4_direction(mm_edge* e, char* function):
	char* suffix = function + index_of(function, c"_") + 1
	if (index_of(function, c"_") < 0): return
	if (strcmp(suffix, c"U") == 0 || strcmp(suffix, c"Up") == 0):
		e.from_port = 3
		e.to_port = 4
	else if (strcmp(suffix, c"D") == 0 || strcmp(suffix, c"Down") == 0):
		e.from_port = 4
		e.to_port = 3
	else if (strcmp(suffix, c"L") == 0 || strcmp(suffix, c"Left") == 0):
		e.from_port = 1
		e.to_port = 2
	else if (strcmp(suffix, c"R") == 0 || strcmp(suffix, c"Right") == 0):
		e.from_port = 2
		e.to_port = 1

void mm_c4_body(mm_parser* p, int scope, int depth);

void mm_c4_node(mm_parser* p, char* function, list[char*] bound, char* signature, int scope, int depth, int offset):
	int group = mm_in_words(function, c"|Boundary|Enterprise_Boundary|System_Boundary|Container_Boundary|Deployment_Node|Node|Node_L|Node_R|")
	int index = mm_add_node(p.doc, bound[0], offset)
	if (index < 0): return
	mm_node* n = p.doc.nodes[index]
	if (n.declared): mm_error(p.doc, offset, c"duplicate C4 node")
	if (index == scope): mm_error(p.doc, offset, c"cyclic C4 boundary")
	n.declared = 1
	n.parent = scope
	n.group = group
	free(n.label)
	n.label = strclone(bound[1])
	free(n.annotation)
	n.annotation = strclone(function)
	for i in range(2, bound.length):
		if (bound[i] == 0): continue
		if (p.doc.attribute_count >= 4096):
			mm_error(p.doc, offset, c"property limit exceeded")
			return
		char* key = mm_c4_param_name(signature, i)
		mm_c4_set(n, key, bound[i])
		free(key)
		p.doc.attribute_count = p.doc.attribute_count + 1
	if (group):
		int save = p.pos
		mm_separators(p)
		if (mm_match(p, c"{") == 0):
			p.pos = save
			mm_error(p.doc, p.pos, c"expected C4 boundary block")
		mm_separators(p)
		if (p.doc.error == 0): mm_c4_body(p, index, depth + 1)

void mm_c4_relation(mm_parser* p, char* function, list[char*] bound, int offset):
	if (p.doc.edges.length >= MM_MAX_ITEMS):
		mm_error(p.doc, offset, c"C4 relationship limit exceeded")
		return
	int first = 0
	if (strcmp(function, c"RelIndex") == 0): first = 1
	int from = mm_add_node(p.doc, bound[first], offset)
	int to = mm_add_node(p.doc, bound[first + 1], offset)
	if (p.doc.error != 0): return
	mm_edge* e = new mm_edge()
	e.from_node = from
	e.to_node = to
	if (strcmp(function, c"Rel_Back") == 0):
		e.from_node = to
		e.to_node = from
	e.right_marker = MM_ARROW
	if (index_of(function, c"BiRel") == 0): e.left_marker = MM_ARROW
	mm_c4_direction(e, function)
	e.left_label = strclone(c"")
	e.right_label = strclone(c"")
	e.scope = -1
	string_builder* label = string_new()
	if (p.doc.graph_variant == 3):
		string_append_int(label, p.doc.edges.length + 1)
		string_append(label, c": ")
	string_append(label, bound[first + 2])
	char* technology = bound[first + 3]
	if (technology != 0 && technology[0] != 0):
		string_append(label, c" [")
		string_append(label, technology)
		string_append_char(label, ']')
	e.label = strclone(label.data)
	string_free(label)
	p.doc.edges.push(e)

void mm_c4_element_style(mm_parser* p, list[char*] bound, int offset):
	int index = mm_add_node(p.doc, bound[0], offset)
	if (index < 0): return
	mm_node* n = p.doc.nodes[index]
	if (bound[1] != 0):
		n.style.fill = mm_c4_color(p, bound[1], offset)
		n.style.mask = n.style.mask | MM_STYLE_FILL
	if (bound[2] != 0):
		n.style.text = mm_c4_color(p, bound[2], offset)
		n.style.mask = n.style.mask | MM_STYLE_TEXT
	if (bound[3] != 0):
		n.style.stroke = mm_c4_color(p, bound[3], offset)
		n.style.mask = n.style.mask | MM_STYLE_STROKE
	if (bound[7] != 0): mm_c4_set(n, c"techn", bound[7])

void mm_c4_relation_style(mm_parser* p, list[char*] bound, int offset):
	int from = mm_find_node(p.doc, bound[0])
	int to = mm_find_node(p.doc, bound[1])
	mm_edge* match = 0
	for mm_edge* e in p.doc.edges:
		if (match == 0 && e.from_node == from && e.to_node == to): match = e
	for mm_edge* e in p.doc.edges:
		if (match == 0 && e.from_node == to && e.to_node == from): match = e
	if (match == 0):
		mm_error(p.doc, offset, c"UpdateRelStyle references no existing relationship")
		return
	if (bound[2] != 0):
		match.style.text = mm_c4_color(p, bound[2], offset)
		match.style.mask = match.style.mask | MM_STYLE_TEXT
	if (bound[3] != 0):
		match.style.stroke = mm_c4_color(p, bound[3], offset)
		match.style.mask = match.style.mask | MM_STYLE_STROKE
	for i in range(2):
		char* text = bound[4 + i]
		if (text == 0): continue
		int value = mm_c4_offset(text)
		if (value == 1000000): mm_error(p.doc, offset, c"C4 offsets must be integers within -2000..2000")
		else if (i == 0): match.label_dx = value
		else: match.label_dy = value

void mm_c4_layout_config(mm_parser* p, list[char*] bound, int offset):
	for i in range(2):
		if (bound[i] == 0): continue
		int value = mm_c4_int(bound[i], 1, 64)
		if (value < 0): mm_error(p.doc, offset, c"UpdateLayoutConfig values must be integers from 1 to 64")
		else if (i == 0): p.doc.c4_shape_in_row = value
		else: p.doc.c4_boundary_in_row = value

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
		int offset = p.pos
		char* function = mm_identifier(p)
		if (strcmp(function, c"title") == 0):
			free(p.doc.title)
			p.doc.title = mm_line_text(p)
			free(function)
			mm_separators(p)
			continue
		char* signature = mm_c4_signature(function)
		if (signature == 0):
			mm_error(p.doc, offset, c"unsupported C4 declaration or configuration")
			free(function)
			return
		mm_c4_call* call = mm_c4_arguments(p)
		int required = 2
		int relation = mm_c4_param(signature, c"from") >= 0 && mm_c4_param(signature, c"textColor") < 0
		if (relation): required = mm_c4_param(signature, c"label") + 1
		if (mm_c4_param(signature, c"elementName") == 0): required = 1
		if (mm_c4_param(signature, c"c4ShapeInRow") == 0): required = 0
		list[char*] bound = 0
		if (p.doc.error == 0): bound = mm_c4_bind(p, call, signature, required, offset)
		if (p.doc.error == 0):
			if (relation): mm_c4_relation(p, function, bound, offset)
			else if (required == 1): mm_c4_element_style(p, bound, offset)
			else if (required == 0): mm_c4_layout_config(p, bound, offset)
			else if (mm_c4_param(signature, c"textColor") >= 0): mm_c4_relation_style(p, bound, offset)
			else: mm_c4_node(p, function, bound, signature, scope, depth, offset)
		if (bound != 0): mm_c4_bound_free(bound)
		mm_c4_call_free(call)
		free(function)
		if (mm_end(p) == 0 && mm_peek(p) != '}'): mm_error(p.doc, p.pos, c"expected C4 statement separator")
		mm_separators(p)
	if (scope >= 0 && p.doc.error == 0): mm_error(p.doc, p.pos, c"unterminated C4 boundary")
	if (scope < 0):
		for mm_node* n in p.doc.nodes:
			if (n.declared == 0): mm_error(p.doc, p.pos, c"C4 relation references undeclared node")
