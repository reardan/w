# Owned Mermaid documents and bounded source edits.
import lib.lib
import lib.str
import structures.string

const int MM_FLOW = 1
const int MM_ER = 2
const int MM_CLASS = 3
const int MM_STATE = 4
const int MM_RAIL_IR = 100
const int MM_RAIL_EBNF = 101
const int MM_RAIL_ABNF = 102
const int MM_RAIL_PEG = 103

# Railroad syntax tree nodes form an owned acyclic tree by index. Repetition
# bounds are annotations on a dedicated loop, never expanded exponentially.
struct mm_rail_expr:
	int kind
	char* text
	list[int] children
	int minimum
	int maximum
	int width
	int height

struct mm_rail_rule:
	char* name
	int expression

struct mm_rail_grammar:
	char* title
	list[mm_rail_expr*] expressions
	list[mm_rail_rule*] rules

const int MM_PIE = 40
const int MM_QUADRANT = 41
const int MM_XY = 42
const int MM_SANKEY = 43
const int MM_RADAR = 44
const int MM_TREEMAP = 45
const int MM_VENN = 46
const int MM_PACKET = 47

# Explicit mask bits distinguish an unspecified color from RGB black.
struct mm_style:
	int mask
	int fill
	int stroke
	int text
	int width

# Data chart values use signed fixed-point thousandths. Counts and bit indices
# are plain integers; interpretation is determined by document and item kind.
struct mm_data_item:
	char* id
	char* label
	char* target
	int kind
	int a
	int b
	int parent
	int depth
	list[int] values
	list[char*] point_labels
	mm_style style
	int radius

struct mm_data_chart:
	char* title
	char* x_label
	char* x_end
	char* y_label
	char* y_end
	list[mm_data_item*] items
	int low
	int high
	int explicit_low
	int explicit_high
	int horizontal
	int x_numeric
	int x_low
	int x_high
	int show_data
	int ticks
	int polygon
	int legend

const int MM_REQUIREMENT = 60
const int MM_MINDMAP = 61
const int MM_KANBAN = 62
const int MM_TREEVIEW = 63
const int MM_ISHIKAWA = 64
const int MM_CYNEFIN = 65
const int MM_WARDLEY = 66
const int MM_GITGRAPH = 67
const int MM_BLOCK = 68
const int MM_ARCHITECTURE = 69
const int MM_USECASE = 71
const int MM_C4 = 70
const int MM_SWIMLANE = 72
const int MM_EVENT_MODEL = 73
const int MM_AGENT = 110
# UML endpoints: open arrow, hollow triangle, filled/hollow diamond.
const int MM_ARROW = 1
const int MM_TRIANGLE = 2
const int MM_COMPOSITION = 3
const int MM_AGGREGATION = 4
const int MM_LOLLIPOP = 7
const int MM_SEQUENCE = 20
const int MM_JOURNEY = 21
const int MM_TIMELINE = 22
const int MM_GANTT = 23
const int MM_ZENUML = 24

# Ordered events own their labels; actor indices refer to document nodes.
struct mm_narrative_event:
	int kind
	int from_node
	int to_node
	char* label
	char* detail
	char* section
	int value
	int start
	int end
	int dashed
	int arrow

const int MM_MAX_SOURCE = 1048576
const int MM_MAX_ITEMS = 1024

struct mm_style_class:
	char* name
	mm_style style

struct mm_attribute:
	char* type_name
	char* name
	char* keys
	char* comment

struct mm_member:
	char* text
	int method

struct mm_property:
	char* key
	char* value

struct mm_node:
	char* id
	char* label
	int shape
	list[mm_attribute*] attributes
	list[mm_member*] members
	char* annotation
	int value_x
	int value_y
	int parent
	int group
	int declared
	char* direction
	mm_style style
	char* style_classes
	char* role
	int global_node
	list[mm_property*] metadata

struct mm_edge:
	int from_node
	int from_port
	int to_port
	int to_node
	char* label
	int dashed
	int arrow
	# Cardinality: 0 = zero/one, 1 = one, 2 = zero/many, 3 = one/many.
	int left_card
	int right_card
	int left_marker
	int right_marker
	char* left_label
	char* right_label
	int scope
	mm_style style

# UML notes are annotations, not graph vertices.
struct mm_note:
	int node
	int side
	char* text

struct mm_document:
	list[mm_note*] notes
	char* source
	int length
	int kind
	int graph_variant
	char* direction
	list[mm_node*] nodes
	list[mm_edge*] edges
	char* error
	int error_offset
	int error_line
	int error_column
	int attribute_count
	char* title
	char* accessibility_title
	char* accessibility_description
	int source_start
	int source_end
	int diagram_index
	# Half-open ranges consumed as real comments by the parser, never label text.
	list[int] comment_ranges
	mm_data_chart* data
	list[mm_narrative_event*] narrative
	# Sequence participant boxes: label, fill in value (-1 none), lanes from/to.
	list[mm_narrative_event*] boxes
	int narrative_numbered
	mm_rail_grammar* railroad
	list[mm_style_class*] style_definitions
	mm_style palette
	int theme
	int background
	int palette_line
	int palette_label
	mm_style edge_style
	# Native layout selection: 0 layered, 1 deterministic force-directed.
	int layout_algorithm
	int packet_bits
	int packet_msb
	# Frontmatter `config: kanban: ticketBaseUrl:`; null when not configured.
	char* ticket_base_url
	# Resolved theme variables (MM_THEME_COUNT colors), non-null when a theme is configured.
	list[int] theme_values
	# Flowchart layout configuration; config_mask bit 1 node spacing, bit 2 rank spacing.
	int config_mask
	int node_spacing
	int rank_spacing
	# 0 orthogonal step (default), 1 linear, 2 basis.
	int edge_curve
	# 0 classic, 1 neo (accepted as a classic approximation).
	int look

mm_document* mm_document_new():
	mm_document* d = new mm_document()
	d.notes = new list[mm_note*]
	d.source = strclone(c"")
	d.title = strclone(c"")
	d.accessibility_title = strclone(c"")
	d.accessibility_description = strclone(c"")
	d.direction = strclone(c"TB")
	d.packet_bits = 32
	d.narrative = new list[mm_narrative_event*]
	d.boxes = new list[mm_narrative_event*]
	d.style_definitions = new list[mm_style_class*]
	d.nodes = new list[mm_node*]
	d.edges = new list[mm_edge*]
	return d

void mm_error(mm_document* d, int offset, char* message):
	if (d.error != 0): return
	d.error = strclone(message)
	d.error_offset = offset
	d.error_line = 1
	d.error_column = 1
	for i in range(offset):
		if (d.source[i] == 10):
			d.error_line = d.error_line + 1
			d.error_column = 1
		else: d.error_column = d.error_column + 1

int mm_find_node(mm_document* d, char* id):
	for i in range(d.nodes.length):
		mm_node* n = d.nodes[i]
		if (strcmp(n.id, id) == 0): return i
	return -1

int mm_add_node(mm_document* d, char* id, int offset):
	int index = mm_find_node(d, id)
	if (index >= 0): return index
	if (d.nodes.length >= MM_MAX_ITEMS):
		mm_error(d, offset, c"node limit exceeded")
		return -1
	mm_node* n = new mm_node()
	n.id = strclone(id)
	n.label = strclone(id)
	n.attributes = new list[mm_attribute*]
	n.members = new list[mm_member*]
	n.annotation = strclone(c"")
	n.direction = strclone(c"")
	n.style_classes = strclone(c"")
	n.role = strclone(c"")
	n.metadata = new list[mm_property*]
	n.parent = -1
	d.nodes.push(n)
	return d.nodes.length - 1

void mm_document_free(mm_document* d):
	if (d == 0): return
	if (d.comment_ranges != 0): __w_list_free(cast(__w_list*, d.comment_ranges))
	if (d.theme_values != 0): __w_list_free(cast(__w_list*, d.theme_values))
	for mm_note* note in d.notes:
		free(note.text)
		free(note)
	__w_list_free(cast(__w_list*, d.notes))
	for mm_node* n in d.nodes:
		for mm_attribute* a in n.attributes:
			free(a.type_name)
			free(a.name)
			free(a.keys)
			free(a.comment)
			free(a)
		__w_list_free(cast(__w_list*, n.attributes))
		for mm_member* m in n.members:
			free(m.text)
			free(m)
		__w_list_free(cast(__w_list*, n.members))
		free(n.style_classes)
		for mm_property* property in n.metadata:
			free(property.key)
			free(property.value)
			free(property)
		__w_list_free(cast(__w_list*, n.metadata))
		free(n.role)
		free(n.annotation)
		free(n.direction)
		free(n.id)
		free(n.label)
		free(n)
	for mm_edge* e in d.edges:
		free(e.label)
		free(e.left_label)
		free(e.right_label)
		free(e)
	__w_list_free(cast(__w_list*, d.nodes))
	__w_list_free(cast(__w_list*, d.edges))
	if (d.railroad != 0):
		for mm_rail_expr* expr in d.railroad.expressions:
			free(expr.text)
			__w_list_free(cast(__w_list*, expr.children))
			free(expr)
		for mm_rail_rule* rule in d.railroad.rules:
			free(rule.name)
			free(rule)
		free(d.railroad.title)
		__w_list_free(cast(__w_list*, d.railroad.expressions))
		__w_list_free(cast(__w_list*, d.railroad.rules))
		free(d.railroad)
	if (d.data != 0):
		for mm_data_item* item in d.data.items:
			free(item.id)
			free(item.label)
			free(item.target)
			for char* label in item.point_labels: free(label)
			__w_list_free(cast(__w_list*, item.point_labels))
			__w_list_free(cast(__w_list*, item.values))
			free(item)
		__w_list_free(cast(__w_list*, d.data.items))
		free(d.data.title)
		free(d.data.x_label)
		free(d.data.x_end)
		free(d.data.y_label)
		free(d.data.y_end)
		free(d.data)
	for mm_narrative_event* event in d.narrative:
		free(event.label)
		free(event.detail)
		free(event.section)
		free(event)
	__w_list_free(cast(__w_list*, d.narrative))
	for mm_narrative_event* box in d.boxes:
		free(box.label)
		free(box.detail)
		free(box.section)
		free(box)
	__w_list_free(cast(__w_list*, d.boxes))
	for mm_style_class* definition in d.style_definitions:
		free(definition.name)
		free(definition)
	__w_list_free(cast(__w_list*, d.style_definitions))
	free(d.source)
	free(d.title)
	free(d.accessibility_title)
	free(d.accessibility_description)
	free(d.direction)
	free(d.error)
	if (d.ticket_base_url != 0): free(d.ticket_base_url)
	free(d)

# Lossless writer, including comments and formatting, even for invalid documents.
char* mm_write(mm_document* d):
	return str_copy_range(d.source, 0, d.length)
