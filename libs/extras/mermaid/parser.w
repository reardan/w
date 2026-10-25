# Diagram dispatch and flowchart / ER parsing.
import libs.extras.mermaid.parse_common
import libs.extras.mermaid.uml
import libs.extras.mermaid.source
import libs.extras.mermaid.data_parse
import libs.extras.mermaid.graph_families
import libs.extras.mermaid.frameworks
import libs.extras.mermaid.gitgraph
import libs.extras.mermaid.blocks
import libs.extras.mermaid.systems
import libs.extras.mermaid.c4
import libs.extras.mermaid.workflows
import libs.extras.mermaid.narrative
import libs.extras.mermaid.railroad_parse
import libs.extras.mermaid.agentflow

int mm_node_parse(mm_parser* p):
	int offset = p.pos
	char* id = mm_identifier(p)
	if (id[0] == 0): mm_error(p.doc, offset, c"empty identifier")
	# These statements need dedicated semantics in subsequent stages.
	if (strcmp(id, c"subgraph") == 0 || strcmp(id, c"end") == 0 || strcmp(id, c"style") == 0 || strcmp(id, c"classDef") == 0 || strcmp(id, c"class") == 0 || strcmp(id, c"click") == 0 || strcmp(id, c"linkStyle") == 0):
		mm_error(p.doc, offset, c"unsupported Mermaid statement in native stage 1")
	int previous = mm_find_node(p.doc, id)
	int index = mm_add_node(p.doc, id, offset)
	free(id)
	if (index < 0 || p.doc.error != 0): return -1
	mm_node* n = p.doc.nodes[index]
	if (p.doc.kind == MM_AGENT && p.global_nodes):
		n.global_node = 1
		n.parent = -1
	if ((p.doc.kind == MM_FLOW || p.doc.kind == MM_ER || p.doc.kind == MM_AGENT) && p.scope >= 0 && n.group == 0 && n.global_node == 0):
		if (previous < 0 || n.parent < 0): n.parent = p.scope
	mm_space(p)
	int close = 0
	int extra = 0
	int flow = p.doc.kind == MM_FLOW || p.doc.kind == MM_AGENT
	if (flow && mm_match(p, c"([")):
		close = ']'
		extra = ')'
		n.shape = 21
	else if (flow && mm_match(p, c"[[")):
		close = ']'
		extra = ']'
		n.shape = 22
	else if (flow && mm_match(p, c"{{")):
		close = '}'
		extra = '}'
		n.shape = 23
	else if (flow && (mm_match(p, c"[/") || mm_match(p, c"[\\"))):
		int opening = p.doc.source[p.pos - 1]
		mm_space(p)
		free(n.label)
		if (mm_peek(p) == '"'):
			n.label = mm_quoted(p)
			mm_space(p)
		else:
			int start = p.pos
			while (mm_peek(p) != 0 && mm_peek(p) != 10):
				if ((mm_peek(p) == '/' || mm_peek(p) == '\\') && p.pos + 1 < p.doc.length && p.doc.source[p.pos + 1] == ']'): break
				p.pos = p.pos + 1
			n.label = mm_style_trim(p.doc.source, start, p.pos)
		int ending = mm_peek(p)
		if (ending != '/' && ending != '\\'): mm_error(p.doc, p.pos, c"expected slanted shape closing delimiter")
		else: p.pos = p.pos + 1
		if (mm_match(p, c"]") == 0): mm_error(p.doc, p.pos, c"expected slanted shape closing bracket")
		n.shape = 24
		if (opening == '\\'): n.shape = 25
		if (opening == '/' && ending == '\\'): n.shape = 26
		if (opening == '\\' && ending == '/'): n.shape = 27
	else if (mm_match(p, c"[")):
		close = ']'
		n.shape = 0
	else if (flow):
		if (mm_match(p, c"((")):
			close = ')'
			extra = ')'
			n.shape = 2
		else if (mm_match(p, c"(")):
			close = ')'
			n.shape = 1
		else if (mm_match(p, c"{")):
			close = '}'
			n.shape = 3
	if (close != 0):
		if (mm_peek(p) == '[' || mm_peek(p) == '(' || mm_peek(p) == '{' || mm_peek(p) == '/' || mm_peek(p) == '\\'): mm_error(p.doc, p.pos, c"unsupported node shape; quote literal labels beginning with a delimiter")
		free(n.label)
		n.label = mm_until(p, close)
		if (extra != 0):
			if (mm_peek(p) != extra): mm_error(p.doc, p.pos, c"expected second closing shape delimiter")
			else: p.pos = p.pos + 1
	if (p.doc.kind == MM_AGENT): mm_agent_metadata(p, n)
	mm_space(p)
	if (mm_match(p, c":::")): mm_style_inline(p, n)
	return index

int mm_card_alias(mm_parser* p, char* text):
	int start = p.pos
	if (mm_match(p, text) == 0): return 0
	if (mm_id_char(mm_peek(p)) || mm_peek(p) == '+'):
		p.pos = start
		return 0
	return 1

int mm_card(mm_parser* p, int left):
	mm_space(p)
	if (mm_card_alias(p, c"one or zero") || mm_card_alias(p, c"zero or one")): return 0
	if (mm_card_alias(p, c"one or more") || mm_card_alias(p, c"one or many") || mm_card_alias(p, c"many(1)") || mm_card_alias(p, c"1+")): return 3
	if (mm_card_alias(p, c"zero or more") || mm_card_alias(p, c"zero or many") || mm_card_alias(p, c"many(0)") || mm_card_alias(p, c"0+")): return 2
	if (mm_card_alias(p, c"only one") || mm_card_alias(p, c"1")): return 1
	if (mm_match(p, c"||")): return 1
	if (left):
		if (mm_match(p, c"|o")): return 0
		if (mm_match(p, c"}o")): return 2
		if (mm_match(p, c"}|")): return 3
	else:
		if (mm_match(p, c"o|")): return 0
		if (mm_match(p, c"o{")): return 2
		if (mm_match(p, c"|{")): return 3
	mm_error(p.doc, p.pos, c"expected ER cardinality marker")
	return 0

void mm_attributes(mm_parser* p, int index):
	mm_node* n = p.doc.nodes[index]
	mm_separators(p)
	while (mm_peek(p) != '}' && p.doc.error == 0):
		if (mm_peek(p) == 0):
			mm_error(p.doc, p.pos, c"unterminated entity attribute block")
			return
		if (n.attributes.length >= MM_MAX_ITEMS || p.doc.attribute_count >= 4096):
			mm_error(p.doc, p.pos, c"attribute limit exceeded")
			return
		mm_attribute* a = new mm_attribute()
		a.type_name = mm_word(p)
		a.name = mm_word(p)
		if (mm_attribute_word(a.type_name, 0) == 0 || mm_attribute_word(a.name, 1) == 0): mm_error(p.doc, p.pos, c"invalid attribute type or name")
		a.keys = strclone(c"")
		a.comment = strclone(c"")
		n.attributes.push(a)
		p.doc.attribute_count = p.doc.attribute_count + 1
		mm_space(p)
		string_builder* keys = string_new()
		while (mm_peek(p) == 'P' || mm_peek(p) == 'F' || mm_peek(p) == 'U'):
			int start = p.pos
			if (mm_match(p, c"PK") == 0 && mm_match(p, c"FK") == 0 && mm_match(p, c"UK") == 0):
				mm_error(p.doc, start, c"expected attribute key PK, FK or UK")
				break
			if (keys.length != 0): string_append(keys, c", ")
			string_append_bytes(keys, p.doc.source + start, 2)
			mm_space(p)
			if (mm_match(p, c",") == 0): break
			mm_space(p)
			if (mm_peek(p) != 'P' && mm_peek(p) != 'F' && mm_peek(p) != 'U'): mm_error(p.doc, p.pos, c"expected key after comma")
		free(a.keys)
		a.keys = strclone(keys.data)
		string_free(keys)
		if (mm_peek(p) == '"'):
			free(a.comment)
			a.comment = mm_quoted(p)
		if (mm_end(p) == 0 && mm_peek(p) != '}'): mm_error(p.doc, p.pos, c"expected end of attribute")
		mm_separators(p)
	if (mm_peek(p) == '}'): p.pos = p.pos + 1

void mm_statement(mm_parser* p):
	int left = mm_node_parse(p)
	if (left < 0): return
	mm_space(p)
	if (p.doc.kind == MM_ER && mm_match(p, c"{")):
		mm_attributes(p, left)
		return
	while (mm_end(p) == 0 && p.doc.error == 0):
		if (p.doc.edges.length >= MM_MAX_ITEMS):
			mm_error(p.doc, p.pos, c"edge limit exceeded")
			return
		mm_edge* e = new mm_edge()
		e.from_node = left
		e.scope = p.scope
		e.label = strclone(c"")
		p.doc.edges.push(e)
		if (p.doc.kind == MM_ER):
			e.left_card = mm_card(p, 1)
			mm_space(p)
			if (mm_match(p, c"..") || mm_keyword(p, c"optionally to")): e.dashed = 1
			else if (mm_match(p, c"--") == 0 && mm_keyword(p, c"to") == 0): mm_error(p.doc, p.pos, c"expected identifying -- or non-identifying .. relationship")
			e.right_card = mm_card(p, 0)
		else:
			if (mm_match(p, c"-->")): e.arrow = 1
			else if (p.doc.kind == MM_AGENT && mm_match(p, c"--x")): e.right_marker = 6
			else if (mm_match(p, c"-.->")):
				e.arrow = 1
				e.dashed = 1
			else if (p.doc.kind == MM_AGENT && mm_match(p, c"-.-")): e.dashed = 1
			else if (mm_match(p, c"---")): e.arrow = 0
			else if (mm_match(p, c"--")):
				mm_space(p)
				int start = p.pos
				while (mm_end(p) == 0):
					int at = p.pos
					if (mm_match(p, c"-->")):
						e.arrow = 1
						int end = at
						while (end > start && (p.doc.source[end - 1] & 255) <= 32): end = end - 1
						free(e.label)
						e.label = str_copy_range(p.doc.source, start, end)
						break
					p.pos = p.pos + 1
				if (e.arrow == 0): mm_error(p.doc, p.pos, c"expected --> after inline edge label")
			else: mm_error(p.doc, p.pos, c"unsupported flowchart edge")
			mm_space(p)
			if (mm_match(p, c"|")):
				free(e.label)
				e.label = mm_until(p, '|')
		if (p.doc.error != 0): return
		e.to_node = mm_node_parse(p)
		if (p.doc.error != 0): return
		if (p.doc.kind == MM_ER):
			mm_space(p)
			if (mm_match(p, c":") == 0):
				mm_error(p.doc, p.pos, c"expected colon and relationship label")
				return
			mm_space(p)
			free(e.label)
			if (mm_peek(p) == '"'): e.label = mm_quoted(p)
			else:
				int start = p.pos
				while (mm_end(p) == 0): p.pos = p.pos + 1
				int end = p.pos
				while (end > start && (p.doc.source[end - 1] & 255) <= 32): end = end - 1
				e.label = str_copy_range(p.doc.source, start, end)
			if (e.label[0] == 0): mm_error(p.doc, p.pos, c"expected relationship label")
			return
		left = e.to_node

void mm_flow_body(mm_parser* p, int depth):
	mm_separators(p)
	while (mm_peek(p) != 0 && p.doc.error == 0):
		if (mm_keyword(p, c"end")):
			if (depth == 0): mm_error(p.doc, p.pos - 3, c"unexpected subgraph end")
			return
		int start = p.pos
		if (mm_metadata(p)): mm_space(p)
		else if (mm_style_statement(p)): mm_space(p)
		else if (p.doc.kind == MM_AGENT && mm_keyword(p, c"global")):
			if (depth >= 32):
				mm_error(p.doc, p.pos, c"agentflow nesting limit exceeded")
				return
			if (mm_end(p) == 0): mm_error(p.doc, p.pos, c"global block takes no label or metadata")
			int outer = p.scope
			int globals = p.global_nodes
			p.scope = -1
			p.global_nodes = 1
			mm_flow_body(p, depth + 1)
			p.scope = outer
			p.global_nodes = globals
		else if (p.doc.kind == MM_AGENT && mm_keyword(p, c"connector")):
			int index = mm_node_parse(p)
			if (index >= 0):
				mm_node* n = p.doc.nodes[index]
				free(n.role)
				n.role = strclone(c"connector")
		else if ((p.doc.kind != MM_AGENT && mm_keyword(p, c"subgraph")) || (p.doc.kind == MM_AGENT && mm_keyword(p, c"flow"))):
			mm_space(p)
			int label_start = p.pos
			char* id = mm_identifier(p)
			mm_space(p)
			char* label
			if (mm_match(p, c"[")): label = mm_until(p, ']')
			else:
				while (mm_end(p) == 0 && (p.doc.kind != MM_AGENT || mm_peek(p) != '@')): p.pos = p.pos + 1
				int end = p.pos
				while (end > label_start && (p.doc.source[end - 1] & 255) <= 32): end = end - 1
				label = str_copy_range(p.doc.source, label_start, end)
			int index = mm_add_node(p.doc, id, start)
			free(id)
			if (index >= 0):
				mm_node* n = p.doc.nodes[index]
				if (n.group || n.parent >= 0 || n.shape != 0): mm_error(p.doc, start, c"duplicate or conflicting subgraph")
				n.group = 1
				if (p.doc.kind == MM_AGENT):
					free(n.role)
					n.role = strclone(c"flow")
				n.parent = p.scope
				if (p.doc.kind == MM_AGENT && p.global_nodes):
					n.global_node = 1
					n.parent = -1
				free(n.label)
				n.label = strclone(label)
				if (p.doc.kind == MM_AGENT): mm_agent_metadata(p, n)
				if (depth >= 32): mm_error(p.doc, start, c"subgraph nesting limit exceeded")
				if (mm_end(p) == 0): mm_error(p.doc, p.pos, c"expected end of subgraph header")
				int outer = p.scope
				int globals = p.global_nodes
				p.scope = index
				p.global_nodes = 0
				if (p.doc.error == 0): mm_flow_body(p, depth + 1)
				p.scope = outer
				p.global_nodes = globals
			free(label)
		else if (mm_keyword(p, c"direction")):
			if (p.scope < 0): mm_direction(p)
			else:
				char* outer = p.doc.direction
				p.doc.direction = strclone(outer)
				mm_direction(p)
				mm_node* n = p.doc.nodes[p.scope]
				free(n.direction)
				n.direction = p.doc.direction
				p.doc.direction = outer
		else: mm_statement(p)
		if (mm_end(p) == 0): mm_error(p.doc, p.pos, c"unsupported syntax or missing statement separator")
		mm_separators(p)
		if (p.pos == start): mm_error(p.doc, start, c"expected flowchart statement")
	if (depth > 0 && p.doc.error == 0): mm_error(p.doc, p.pos, c"unterminated subgraph")

mm_document* mm_parse_raw(char* source, int length):
	mm_document* d = mm_document_new()
	if (length < 0 || length > MM_MAX_SOURCE || (source == 0 && length != 0)):
		mm_error(d, 0, c"invalid input or source limit exceeded")
		return d
	free(d.source)
	d.source = str_copy_range(source, 0, length)
	d.length = length
	if (utf8_validate_bytes(source, length) == 0):
		mm_error(d, 0, c"invalid UTF-8 source")
		return d
	for i in range(length):
		if (source[i] == 0):
			mm_error(d, i, c"embedded NUL in Mermaid source")
			return d
		if ((source[i] & 255) < 32 && source[i] != 9 && source[i] != 10 && source[i] != 13):
			mm_error(d, i, c"unsupported control character")
			return d
	mm_parser p
	p.doc = d
	p.pos = 0
	p.scope = -1
	p.global_nodes = 0
	p.markdown_unclosed = 0
	if (length >= 3 && (source[0] & 255) == 239 && (source[1] & 255) == 187 && (source[2] & 255) == 191): p.pos = 3
	mm_separators(&p)
	char* header = mm_identifier(&p)
	if (strcmp(header, c"erDiagram") == 0): d.kind = MM_ER
	else if (strcmp(header, c"flowchart") == 0 || strcmp(header, c"graph") == 0): d.kind = MM_FLOW
	else if (strcmp(header, c"requirementDiagram") == 0): d.kind = MM_REQUIREMENT
	else if (strcmp(header, c"mindmap") == 0): d.kind = MM_MINDMAP
	else if (strcmp(header, c"kanban") == 0): d.kind = MM_KANBAN
	else if (strcmp(header, c"treeView") == 0):
		d.kind = MM_TREEVIEW
		mm_match(&p, c"-beta")
	else if (strcmp(header, c"ishikawa") == 0):
		d.kind = MM_ISHIKAWA
		mm_match(&p, c"-beta")
	else if (strcmp(header, c"cynefin") == 0):
		d.kind = MM_CYNEFIN
		mm_match(&p, c"-beta")
	else if (strcmp(header, c"wardley") == 0):
		d.kind = MM_WARDLEY
		mm_match(&p, c"-beta")
	else if (strcmp(header, c"gitGraph") == 0):
		d.kind = MM_GITGRAPH
		free(d.direction)
		d.direction = strclone(c"LR")
		mm_space(&p)
		if (mm_match(&p, c"LR")): mm_space(&p)
		else if (mm_match(&p, c"TB")):
			free(d.direction)
			d.direction = strclone(c"TB")
		else if (mm_match(&p, c"BT")):
			free(d.direction)
			d.direction = strclone(c"BT")
		mm_match(&p, c":")
	else if (strcmp(header, c"block") == 0):
		d.kind = MM_BLOCK
		mm_match(&p, c"-beta")
	else if (strcmp(header, c"architecture") == 0):
		d.kind = MM_ARCHITECTURE
		mm_match(&p, c"-beta")
	else if (strcmp(header, c"usecase") == 0):
		d.kind = MM_USECASE
		mm_match(&p, c"-beta")
	else if (mm_in_words(header, c"|C4Context|C4Container|C4Component|C4Dynamic|C4Deployment|")):
		d.kind = MM_C4
		if (strcmp(header, c"C4Container") == 0): d.graph_variant = 1
		if (strcmp(header, c"C4Component") == 0): d.graph_variant = 2
		if (strcmp(header, c"C4Dynamic") == 0): d.graph_variant = 3
		if (strcmp(header, c"C4Deployment") == 0): d.graph_variant = 4
	else if (strcmp(header, c"swimlane") == 0):
		d.kind = MM_SWIMLANE
		mm_match(&p, c"-beta")
		if (mm_end(&p) == 0): mm_direction(&p)
	else if (strcmp(header, c"eventmodeling") == 0): d.kind = MM_EVENT_MODEL
	else if (strcmp(header, c"sequenceDiagram") == 0): d.kind = MM_SEQUENCE
	else if (strcmp(header, c"journey") == 0): d.kind = MM_JOURNEY
	else if (strcmp(header, c"timeline") == 0): d.kind = MM_TIMELINE
	else if (strcmp(header, c"gantt") == 0): d.kind = MM_GANTT
	else if (strcmp(header, c"zenuml") == 0): d.kind = MM_ZENUML
	else if (strcmp(header, c"agentflow") == 0):
		d.kind = MM_AGENT
		if (mm_match(&p, c"-beta") == 0): mm_error(d, p.pos, c"expected agentflow-beta")
	else if (strcmp(header, c"classDiagram") == 0): d.kind = MM_CLASS
	else if (strcmp(header, c"stateDiagram") == 0):
		d.kind = MM_STATE
		mm_match(&p, c"-v2")
	else if (strcmp(header, c"railroad") == 0):
		d.kind = MM_RAIL_IR
		if (mm_match(&p, c"-ebnf")): d.kind = MM_RAIL_EBNF
		else if (mm_match(&p, c"-abnf")): d.kind = MM_RAIL_ABNF
		else if (mm_match(&p, c"-peg")): d.kind = MM_RAIL_PEG
		if (mm_match(&p, c"-beta") == 0): mm_error(d, p.pos, c"expected railroad -beta suffix")
		mm_rail_new(d)
	else if (strcmp(header, c"pie") == 0): d.kind = MM_PIE
	else if (strcmp(header, c"quadrantChart") == 0): d.kind = MM_QUADRANT
	else if (strcmp(header, c"xychart") == 0): d.kind = MM_XY
	else if (strcmp(header, c"sankey") == 0): d.kind = MM_SANKEY
	else if (strcmp(header, c"radar") == 0): d.kind = MM_RADAR
	else if (strcmp(header, c"treemap") == 0): d.kind = MM_TREEMAP
	else if (strcmp(header, c"venn") == 0): d.kind = MM_VENN
	else if (strcmp(header, c"packet") == 0): d.kind = MM_PACKET
	else: mm_error(d, 0, c"unsupported diagram type")
	free(header)
	if (d.kind >= MM_PIE && d.kind <= MM_PACKET):
		mm_data_chart* chart = mm_data_new(d)
		if (d.kind != MM_PIE && d.kind != MM_QUADRANT): mm_match(&p, c"-beta")
		mm_space(&p)
		if (d.kind == MM_PIE): chart.show_data = mm_match(&p, c"showData")
		if (d.kind == MM_XY): chart.horizontal = mm_match(&p, c"horizontal")
		mm_space(&p)
		if (mm_match(&p, c"title ")):
			free(chart.title)
			chart.title = mm_data_text(&p, 10)
	if (d.kind == MM_FLOW): mm_direction(&p)
	if (d.kind == MM_AGENT && mm_end(&p) == 0): mm_direction(&p)
	if (mm_end(&p) == 0): mm_error(d, p.pos, c"expected end of diagram header")
	if (d.kind == MM_TREEVIEW || d.kind == MM_ISHIKAWA):
		mm_outline_body(&p)
		return d
	if (d.kind == MM_MINDMAP || d.kind == MM_KANBAN):
		mm_hierarchy_body(&p)
		return d
	if (d.kind >= MM_RAIL_IR && d.kind <= MM_RAIL_PEG):
		mm_rail_body(&p)
		return d
	mm_separators(&p)
	if (d.kind == MM_FLOW || d.kind == MM_ER || d.kind == MM_AGENT):
		mm_flow_body(&p, 0)
		return d
	if (d.kind >= MM_PIE && d.kind <= MM_PACKET):
		mm_data_body(&p)
		return d
	if (d.kind == MM_SWIMLANE):
		mm_swimlane_body(&p)
		return d
	if (d.kind == MM_EVENT_MODEL):
		mm_event_body(&p)
		return d
	if (d.kind == MM_C4):
		mm_c4_body(&p, -1, 0)
		return d
	if (d.kind == MM_ARCHITECTURE):
		mm_arch_body(&p)
		return d
	if (d.kind == MM_USECASE):
		mm_usecase_body(&p, -1)
		return d
	if (d.kind == MM_BLOCK):
		mm_blocks_parse(&p)
		return d
	if (d.kind == MM_GITGRAPH):
		mm_git_body(&p)
		return d
	if (d.kind == MM_CYNEFIN):
		mm_cynefin_body(&p)
		return d
	if (d.kind == MM_WARDLEY):
		mm_wardley_body(&p)
		return d
	if (d.kind == MM_REQUIREMENT):
		mm_requirement_body(&p)
		return d
	if (d.kind >= MM_SEQUENCE && d.kind <= MM_ZENUML):
		mm_narrative_body(&p)
		return d
	if (d.kind == MM_CLASS || d.kind == MM_STATE):
		mm_uml_body(&p, -1, 0)
		return d
	while (mm_peek(&p) != 0 && d.error == 0):
		int start = p.pos
		if (mm_match(&p, c"direction ")): mm_direction(&p)
		else: mm_statement(&p)
		if (mm_end(&p) == 0): mm_error(d, p.pos, c"unsupported syntax or missing statement separator")
		mm_separators(&p)
		if (p.pos == start): mm_error(d, start, c"expected Mermaid statement")
	return d

# Parse an optional Markdown/frontmatter envelope without losing its bytes.
mm_document* mm_parse_selected(char* source, int length, int selected):
	mm_document* envelope = mm_source_prepare_selected(source, length, selected)
	envelope.diagram_index = selected
	if (envelope.error != 0): return envelope
	int start = envelope.source_start
	mm_document* d = mm_parse_raw(envelope.source + start, envelope.source_end - start)
	mm_style_adopt(d, envelope)
	mm_style_validate(d)
	d.palette = envelope.palette
	d.background = envelope.background
	d.palette_line = envelope.palette_line
	d.palette_label = envelope.palette_label
	d.theme = envelope.theme
	d.packet_bits = envelope.packet_bits
	d.packet_msb = envelope.packet_msb
	d.layout_algorithm = envelope.layout_algorithm
	d.ticket_base_url = envelope.ticket_base_url
	envelope.ticket_base_url = 0
	d.theme_values = envelope.theme_values
	envelope.theme_values = 0
	d.config_mask = envelope.config_mask
	d.node_spacing = envelope.node_spacing
	d.rank_spacing = envelope.rank_spacing
	d.edge_curve = envelope.edge_curve
	d.look = envelope.look
	if (d.layout_algorithm == 1 && d.kind != MM_FLOW && d.kind != MM_ER && d.kind != MM_CLASS && d.kind != MM_STATE && d.kind != MM_REQUIREMENT && d.kind != MM_C4 && d.kind != MM_ARCHITECTURE && d.kind != MM_USECASE && d.kind != MM_AGENT): mm_error(d, 0, c"force layout is only supported for graph diagrams")
	free(d.source)
	d.source = envelope.source
	envelope.source = 0
	d.length = envelope.length
	d.source_start = start
	if (d.comment_ranges != 0):
		for i in range(d.comment_ranges.length): d.comment_ranges[i] = d.comment_ranges[i] + start
	d.source_end = envelope.source_end
	d.diagram_index = selected
	if (envelope.title[0] != 0):
		free(d.title)
		d.title = strclone(envelope.title)
	if (d.title[0] == 0 && d.data != 0):
		free(d.title)
		d.title = strclone(d.data.title)
	if (d.title[0] == 0 && d.railroad != 0):
		free(d.title)
		d.title = strclone(d.railroad.title)
	if (d.error != 0):
		char* message = d.error
		d.error = 0
		mm_error(d, start + d.error_offset, message)
		free(message)
	mm_document_free(envelope)
	return d

mm_document* mm_parse(char* source, int length):
	return mm_parse_selected(source, length, 0)

# Immutable edit: result owns a reparsed copy; original is always unchanged.
# Returns null for an invalid range/budget or an edit splitting a UTF-8 codepoint.
mm_document* mm_edit(mm_document* d, int start, int end, char* replacement, int length):
	if (start < 0 || end < start || end > d.length || length < 0 || length > MM_MAX_SOURCE - (d.length - (end - start))): return 0
	if (replacement == 0 && length != 0): return 0
	if (start < d.length && (d.source[start] & 192) == 128): return 0
	if (end < d.length && (d.source[end] & 192) == 128): return 0
	string_builder* s = string_new()
	string_append_bytes(s, d.source, start)
	string_append_bytes(s, replacement, length)
	string_append_bytes(s, d.source + end, d.length - end)
	mm_document* result = mm_parse_selected(s.data, s.length, d.diagram_index)
	string_free(s)
	return result
