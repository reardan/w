# Owned Mermaid documents and bounded source edits.
import lib.lib
import lib.str
import structures.string

const int MM_FLOW = 1
const int MM_ER = 2
const int MM_CLASS = 3
const int MM_STATE = 4
const int MM_PIE = 40
const int MM_QUADRANT = 41
const int MM_XY = 42
const int MM_SANKEY = 43
const int MM_RADAR = 44
const int MM_TREEMAP = 45
const int MM_VENN = 46
const int MM_PACKET = 47

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
# UML endpoints: open arrow, hollow triangle, filled/hollow diamond.
const int MM_ARROW = 1
const int MM_TRIANGLE = 2
const int MM_COMPOSITION = 3
const int MM_AGGREGATION = 4
const int MM_MAX_SOURCE = 1048576
const int MM_MAX_ITEMS = 1024

struct mm_attribute:
	char* type_name
	char* name
	char* keys
	char* comment

struct mm_member:
	char* text
	int method

struct mm_node:
	char* id
	char* label
	int shape
	list[mm_attribute*] attributes
	list[mm_member*] members
	char* annotation
	int parent
	int group
	int declared
	char* direction

struct mm_edge:
	int from_node
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

struct mm_document:
	char* source
	int length
	int kind
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
	mm_data_chart* data

mm_document* mm_document_new():
	mm_document* d = new mm_document()
	d.source = strclone(c"")
	d.title = strclone(c"")
	d.accessibility_title = strclone(c"")
	d.accessibility_description = strclone(c"")
	d.direction = strclone(c"TB")
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
	n.parent = -1
	d.nodes.push(n)
	return d.nodes.length - 1

void mm_document_free(mm_document* d):
	if (d == 0): return
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
	free(d.source)
	free(d.title)
	free(d.accessibility_title)
	free(d.accessibility_description)
	free(d.direction)
	free(d.error)
	free(d)

# Lossless writer, including comments and formatting, even for invalid documents.
char* mm_write(mm_document* d):
	return str_copy_range(d.source, 0, d.length)
