# Flowchart syntax extensions against Mermaid 12.2.0: the named `A@{ shape: ... }`
# inventory with icon/image nodes, the full link grammar (thick, dotted,
# invisible, extended lengths, both-ended markers, edge IDs) and edge metadata.
import libs.extras.mermaid.parse_common
import libs.extras.mermaid.interaction
import libs.extras.mermaid.graph_families

# Endpoint codes in mm_edge.left_marker / right_marker for flowchart links.
# An end arrow is mm_edge.arrow; a start arrow is left_marker MM_ARROW.
const int MM_FLOW_CROSS = 6
const int MM_FLOW_CIRCLE = 8

# Shape codes beyond the bracket shapes (0-3, 21-27) of the base parser.
const int MM_FLOW_CYLINDER = 40
const int MM_FLOW_ODD = 41
const int MM_FLOW_DOUBLE_CIRCLE = 42
const int MM_FLOW_SMALL_CIRCLE = 43
const int MM_FLOW_FRAMED_CIRCLE = 44
const int MM_FLOW_FILLED_CIRCLE = 45
const int MM_FLOW_CROSSED_CIRCLE = 46
const int MM_FLOW_DOCUMENT = 47
const int MM_FLOW_LINED_DOCUMENT = 48
const int MM_FLOW_STACKED_DOCUMENT = 49
const int MM_FLOW_TAGGED_DOCUMENT = 50
const int MM_FLOW_STACKED_RECT = 51
const int MM_FLOW_LINED_RECT = 52
const int MM_FLOW_DIVIDED_RECT = 53
const int MM_FLOW_TAGGED_RECT = 54
const int MM_FLOW_WINDOW_PANE = 55
const int MM_FLOW_NOTCHED_RECT = 56
const int MM_FLOW_SLOPED_RECT = 57
const int MM_FLOW_BOW_TIE = 58
const int MM_FLOW_H_CYLINDER = 59
const int MM_FLOW_LINED_CYLINDER = 60
const int MM_FLOW_CURVED_TRAPEZOID = 61
const int MM_FLOW_DELAY = 62
const int MM_FLOW_TRIANGLE = 63
const int MM_FLOW_FLIPPED_TRIANGLE = 64
const int MM_FLOW_HOURGLASS = 65
const int MM_FLOW_BOLT = 66
const int MM_FLOW_BRACE_LEFT = 67
const int MM_FLOW_BRACE_RIGHT = 68
const int MM_FLOW_BRACES = 69
const int MM_FLOW_FLAG = 70
const int MM_FLOW_FORK = 71
const int MM_FLOW_LOOP_LIMIT = 72
const int MM_FLOW_TEXT = 73
const int MM_FLOW_ICON = 74
const int MM_FLOW_IMAGE = 75
const int MM_FLOW_DATASTORE = 76

# Shape names and aliases of the upstream shape table; -1 when unknown.
int mm_flow_shape_code(char* name):
	if (strlen(name) > 64): return -1
	if (mm_in_words(name, c"|rect|rectangle|proc|process|")): return 0
	if (mm_in_words(name, c"|rounded|event|")): return 1
	if (mm_in_words(name, c"|circle|circ|")): return 2
	if (mm_in_words(name, c"|diamond|diam|decision|question|")): return 3
	if (mm_in_words(name, c"|stadium|pill|terminal|")): return 21
	if (mm_in_words(name, c"|subproc|subprocess|subroutine|fr-rect|framed-rectangle|")): return 22
	if (mm_in_words(name, c"|hex|hexagon|prepare|")): return 23
	if (mm_in_words(name, c"|lean-r|lean-right|in-out|")): return 24
	if (mm_in_words(name, c"|lean-l|lean-left|out-in|")): return 25
	if (mm_in_words(name, c"|trap-b|trapezoid|trapezoid-base-bottom|priority|")): return 26
	if (mm_in_words(name, c"|trap-t|inv-trapezoid|trapezoid-base-top|manual|")): return 27
	if (mm_in_words(name, c"|cyl|cylinder|database|db|")): return MM_FLOW_CYLINDER
	if (mm_in_words(name, c"|odd|")): return MM_FLOW_ODD
	if (mm_in_words(name, c"|dbl-circ|double-circle|")): return MM_FLOW_DOUBLE_CIRCLE
	if (mm_in_words(name, c"|sm-circ|small-circle|start|")): return MM_FLOW_SMALL_CIRCLE
	if (mm_in_words(name, c"|fr-circ|framed-circle|stop|")): return MM_FLOW_FRAMED_CIRCLE
	if (mm_in_words(name, c"|f-circ|filled-circle|junction|")): return MM_FLOW_FILLED_CIRCLE
	if (mm_in_words(name, c"|cross-circ|crossed-circle|summary|")): return MM_FLOW_CROSSED_CIRCLE
	if (mm_in_words(name, c"|doc|document|")): return MM_FLOW_DOCUMENT
	if (mm_in_words(name, c"|lin-doc|lined-document|")): return MM_FLOW_LINED_DOCUMENT
	if (mm_in_words(name, c"|docs|documents|st-doc|stacked-document|")): return MM_FLOW_STACKED_DOCUMENT
	if (mm_in_words(name, c"|tag-doc|tagged-document|")): return MM_FLOW_TAGGED_DOCUMENT
	if (mm_in_words(name, c"|procs|processes|st-rect|stacked-rectangle|")): return MM_FLOW_STACKED_RECT
	if (mm_in_words(name, c"|lin-rect|lined-rectangle|lin-proc|lined-process|shaded-process|")): return MM_FLOW_LINED_RECT
	if (mm_in_words(name, c"|div-rect|divided-rectangle|div-proc|divided-process|")): return MM_FLOW_DIVIDED_RECT
	if (mm_in_words(name, c"|tag-rect|tagged-rectangle|tag-proc|tagged-process|")): return MM_FLOW_TAGGED_RECT
	if (mm_in_words(name, c"|win-pane|window-pane|internal-storage|")): return MM_FLOW_WINDOW_PANE
	if (mm_in_words(name, c"|notch-rect|notched-rectangle|card|")): return MM_FLOW_NOTCHED_RECT
	if (mm_in_words(name, c"|sl-rect|sloped-rectangle|manual-input|")): return MM_FLOW_SLOPED_RECT
	if (mm_in_words(name, c"|bow-rect|bow-tie-rectangle|stored-data|")): return MM_FLOW_BOW_TIE
	if (mm_in_words(name, c"|h-cyl|horizontal-cylinder|das|")): return MM_FLOW_H_CYLINDER
	if (mm_in_words(name, c"|lin-cyl|lined-cylinder|disk|")): return MM_FLOW_LINED_CYLINDER
	if (mm_in_words(name, c"|curv-trap|curved-trapezoid|display|")): return MM_FLOW_CURVED_TRAPEZOID
	if (mm_in_words(name, c"|delay|half-rounded-rectangle|")): return MM_FLOW_DELAY
	if (mm_in_words(name, c"|tri|triangle|extract|")): return MM_FLOW_TRIANGLE
	if (mm_in_words(name, c"|flip-tri|flipped-triangle|manual-file|")): return MM_FLOW_FLIPPED_TRIANGLE
	if (mm_in_words(name, c"|hourglass|collate|")): return MM_FLOW_HOURGLASS
	if (mm_in_words(name, c"|bolt|com-link|lightning-bolt|")): return MM_FLOW_BOLT
	if (mm_in_words(name, c"|brace|brace-l|comment|")): return MM_FLOW_BRACE_LEFT
	if (mm_in_words(name, c"|brace-r|")): return MM_FLOW_BRACE_RIGHT
	if (mm_in_words(name, c"|braces|")): return MM_FLOW_BRACES
	if (mm_in_words(name, c"|flag|paper-tape|")): return MM_FLOW_FLAG
	if (mm_in_words(name, c"|fork|join|")): return MM_FLOW_FORK
	if (mm_in_words(name, c"|notch-pent|trapezoidal-pentagon|loop-limit|")): return MM_FLOW_LOOP_LIMIT
	if (mm_in_words(name, c"|text|")): return MM_FLOW_TEXT
	if (mm_in_words(name, c"|datastore|")): return MM_FLOW_DATASTORE
	return -1

# Canonical short name used by the serializer, or null for bracket-only shapes.
char* mm_flow_shape_name(int shape):
	if (shape == MM_FLOW_CYLINDER): return c"cyl"
	if (shape == MM_FLOW_ODD): return c"odd"
	if (shape == MM_FLOW_DOUBLE_CIRCLE): return c"dbl-circ"
	if (shape == MM_FLOW_SMALL_CIRCLE): return c"sm-circ"
	if (shape == MM_FLOW_FRAMED_CIRCLE): return c"fr-circ"
	if (shape == MM_FLOW_FILLED_CIRCLE): return c"f-circ"
	if (shape == MM_FLOW_CROSSED_CIRCLE): return c"cross-circ"
	if (shape == MM_FLOW_DOCUMENT): return c"doc"
	if (shape == MM_FLOW_LINED_DOCUMENT): return c"lin-doc"
	if (shape == MM_FLOW_STACKED_DOCUMENT): return c"docs"
	if (shape == MM_FLOW_TAGGED_DOCUMENT): return c"tag-doc"
	if (shape == MM_FLOW_STACKED_RECT): return c"procs"
	if (shape == MM_FLOW_LINED_RECT): return c"lin-rect"
	if (shape == MM_FLOW_DIVIDED_RECT): return c"div-rect"
	if (shape == MM_FLOW_TAGGED_RECT): return c"tag-rect"
	if (shape == MM_FLOW_WINDOW_PANE): return c"win-pane"
	if (shape == MM_FLOW_NOTCHED_RECT): return c"notch-rect"
	if (shape == MM_FLOW_SLOPED_RECT): return c"sl-rect"
	if (shape == MM_FLOW_BOW_TIE): return c"bow-rect"
	if (shape == MM_FLOW_H_CYLINDER): return c"h-cyl"
	if (shape == MM_FLOW_LINED_CYLINDER): return c"lin-cyl"
	if (shape == MM_FLOW_CURVED_TRAPEZOID): return c"curv-trap"
	if (shape == MM_FLOW_DELAY): return c"delay"
	if (shape == MM_FLOW_TRIANGLE): return c"tri"
	if (shape == MM_FLOW_FLIPPED_TRIANGLE): return c"flip-tri"
	if (shape == MM_FLOW_HOURGLASS): return c"hourglass"
	if (shape == MM_FLOW_BOLT): return c"bolt"
	if (shape == MM_FLOW_BRACE_LEFT): return c"comment"
	if (shape == MM_FLOW_BRACE_RIGHT): return c"brace-r"
	if (shape == MM_FLOW_BRACES): return c"braces"
	if (shape == MM_FLOW_FLAG): return c"flag"
	if (shape == MM_FLOW_FORK): return c"fork"
	if (shape == MM_FLOW_LOOP_LIMIT): return c"notch-pent"
	if (shape == MM_FLOW_TEXT): return c"text"
	if (shape == MM_FLOW_DATASTORE): return c"datastore"
	return 0

char* mm_flow_property(mm_node* n, char* key):
	for mm_property* property in n.metadata:
		if (strcmp(property.key, key) == 0): return property.value
	return 0

void mm_flow_property_set(mm_parser* p, list[mm_property*] metadata, char* key, char* value):
	for mm_property* property in metadata:
		if (strcmp(property.key, key) == 0):
			free(property.value)
			property.value = strclone(value)
			return
	if (metadata.length >= 64):
		mm_error(p.doc, p.pos, c"flowchart metadata limit exceeded (64 per item)")
		return
	metadata.push(new mm_property(strclone(key), strclone(value), MM_VALUE_STRING))

int mm_flow_dimension(char* value):
	int n = 0
	int i = 0
	if (value[0] == 0): return -1
	while (value[i] != 0):
		if (value[i] < '0' || value[i] > '9' || n > 100000): return -1
		n = n * 10 + value[i] - '0'
		i = i + 1
	if (n > 4096): return -1
	return n

# One `key: value` pair of an `@{ ... }` block; returns 0 at the closing brace.
int mm_flow_pair(mm_parser* p, char** key, char** value):
	while (1):
		mm_space(p)
		if (mm_peek(p) == 10 || mm_peek(p) == ','): p.pos = p.pos + 1
		else: break
	if (mm_match(p, c"}")): return 0
	if (mm_peek(p) == 0):
		mm_error(p.doc, p.pos, c"unterminated metadata block")
		return 0
	int start = p.pos
	while (mm_id_char(mm_peek(p)) || mm_peek(p) == '-'): p.pos = p.pos + 1
	if (p.pos == start):
		mm_error(p.doc, p.pos, c"expected metadata key")
		return 0
	key[0] = str_copy_range(p.doc.source, start, p.pos)
	mm_space(p)
	if (mm_match(p, c":") == 0):
		mm_error(p.doc, p.pos, c"expected colon after metadata key")
		value[0] = strclone(c"")
		return 1
	mm_space(p)
	if (mm_peek(p) == '"'): value[0] = mm_quoted(p)
	else if (mm_peek(p) == 39):
		p.pos = p.pos + 1
		int at = p.pos
		while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != 39): p.pos = p.pos + 1
		value[0] = str_copy_range(p.doc.source, at, p.pos)
		if (mm_match(p, c"'") == 0): mm_error(p.doc, at - 1, c"unterminated quoted text")
	else:
		int at = p.pos
		while (mm_peek(p) != 0 && mm_peek(p) != 10 && mm_peek(p) != ',' && mm_peek(p) != '}'):
			if (mm_peek(p) == '{' || mm_peek(p) == '['): mm_error(p.doc, p.pos, c"structured YAML metadata is not yet supported")
			p.pos = p.pos + 1
		value[0] = mm_style_trim(p.doc.source, at, p.pos)
		if (value[0][0] == 0): mm_error(p.doc, at, c"expected metadata value")
	return 1

# Node metadata after `ID@{`. Every pair is kept in n.metadata; the ones with
# rendering semantics are validated here.
void mm_flow_node_metadata(mm_parser* p, mm_node* n):
	int at = p.pos
	char* key = 0
	char* value = 0
	while (p.doc.error == 0 && mm_flow_pair(p, &key, &value)):
		if (p.doc.error == 0):
			if (strcmp(key, c"shape") == 0):
				int code = mm_flow_shape_code(value)
				if (code < 0): mm_error(p.doc, at, c"unknown flowchart shape name")
				else if (n.group): mm_error(p.doc, at, c"subgraphs take no shape")
				else: n.shape = code
			else if (strcmp(key, c"label") == 0):
				free(n.label)
				n.label = strclone(value)
			else if (strcmp(key, c"icon") == 0):
				if (n.group): mm_error(p.doc, at, c"subgraphs take no icon")
				n.shape = MM_FLOW_ICON
			else if (strcmp(key, c"img") == 0):
				if (n.group): mm_error(p.doc, at, c"subgraphs take no image")
				n.shape = MM_FLOW_IMAGE
			else if (strcmp(key, c"form") == 0):
				if (mm_in_words(value, c"|square|circle|rounded|") == 0): mm_error(p.doc, at, c"expected icon form square, circle or rounded")
			else if (strcmp(key, c"pos") == 0):
				if (strcmp(value, c"t") != 0 && strcmp(value, c"b") != 0): mm_error(p.doc, at, c"expected label position t or b")
			else if (strcmp(key, c"w") == 0 || strcmp(key, c"h") == 0):
				if (mm_flow_dimension(value) < 0): mm_error(p.doc, at, c"expected a width or height of at most 4096")
			else if (strcmp(key, c"constraint") == 0):
				if (strcmp(value, c"on") != 0 && strcmp(value, c"off") != 0): mm_error(p.doc, at, c"expected image constraint on or off")
			else if (strcmp(key, c"view") == 0):
				if (strcmp(value, c"collapsed") != 0 && strcmp(value, c"expanded") != 0): mm_error(p.doc, at, c"expected subgraph view collapsed or expanded")
			else if (strcmp(key, c"labelType") == 0):
				if (strcmp(value, c"text") != 0 && strcmp(value, c"string") != 0 && strcmp(value, c"markdown") != 0): mm_error(p.doc, at, c"unsupported label type")
			else: mm_error(p.doc, at, c"unsupported flowchart node metadata; supported: shape, label, icon, form, img, pos, w, h, constraint, view, labelType")
			if (p.doc.error == 0): mm_flow_property_set(p, n.metadata, key, value)
		free(key)
		free(value)
		key = 0
		value = 0
	if (key != 0): free(key)
	if (value != 0): free(value)

int mm_flow_edge_find(mm_document* d, char* id):
	for i in range(d.edges.length):
		mm_edge* e = d.edges[i]
		if (e.id != 0 && strcmp(e.id, id) == 0): return i
	return -1

int mm_flow_curve(char* value):
	if (mm_in_words(value, c"|step|stepBefore|stepAfter|")): return 1
	if (strcmp(value, c"linear") == 0): return 2
	if (mm_in_words(value, c"|basis|bumpX|bumpY|cardinal|catmullRom|monotoneX|monotoneY|natural|")): return 3
	return 0

# Edge metadata after `ID@{` for an existing edge ID.
void mm_flow_edge_metadata(mm_parser* p, mm_edge* e):
	int at = p.pos
	char* key = 0
	char* value = 0
	while (p.doc.error == 0 && mm_flow_pair(p, &key, &value)):
		if (p.doc.error == 0):
			if (strcmp(key, c"animate") == 0):
				if (strcmp(value, c"true") == 0): e.animate = 1
				else if (strcmp(value, c"false") == 0): e.animate = 0
				else: mm_error(p.doc, at, c"expected animate true or false")
			else if (strcmp(key, c"animation") == 0):
				if (strcmp(value, c"fast") == 0): e.animate = 2
				else if (strcmp(value, c"slow") == 0): e.animate = 3
				else if (strcmp(value, c"none") == 0): e.animate = 0
				else: mm_error(p.doc, at, c"expected animation fast, slow or none")
			else if (strcmp(key, c"curve") == 0):
				e.curve = mm_flow_curve(value)
				if (e.curve == 0): mm_error(p.doc, at, c"unsupported edge curve; supported: basis, bumpX, bumpY, cardinal, catmullRom, linear, monotoneX, monotoneY, natural, step, stepBefore, stepAfter")
			else: mm_error(p.doc, at, c"unsupported flowchart edge metadata; supported: animate, animation, curve")
		free(key)
		free(value)
		key = 0
		value = 0
	if (key != 0): free(key)
	if (value != 0): free(value)

# `ID@` immediately before a link; null (position unchanged) otherwise.
char* mm_flow_edge_id(mm_parser* p):
	int start = p.pos
	while (mm_id_char(mm_peek(p))): p.pos = p.pos + 1
	if (p.pos == start || mm_peek(p) != '@' || p.pos + 1 >= p.doc.length):
		p.pos = start
		return 0
	int c = p.doc.source[p.pos + 1] & 255
	if (c != '-' && c != '=' && c != '~' && c != '<' && c != 'o' && c != 'x' && c != '.'):
		p.pos = start
		return 0
	char* id = str_copy_range(p.doc.source, start, p.pos)
	p.pos = p.pos + 1
	return id

int mm_flow_at(mm_parser* p, int offset):
	if (p.pos + offset >= p.doc.length): return 0
	return p.doc.source[p.pos + offset] & 255

# An `o`/`x` end marker is a marker only when no identifier continues it, so
# `A---oak` links to node `oak` (upstream would read a circle end).
int mm_flow_end_marker(mm_parser* p, mm_edge* e):
	int c = mm_peek(p)
	if (c == '>'):
		e.arrow = 1
		p.pos = p.pos + 1
		return 1
	if ((c == 'o' || c == 'x') && mm_id_char(mm_flow_at(p, 1)) == 0):
		e.right_marker = MM_FLOW_CROSS
		if (c == 'o'): e.right_marker = MM_FLOW_CIRCLE
		p.pos = p.pos + 1
		return 1
	return 0

# Count a run of `c` (bounded so lengths stay layout-sized).
int mm_flow_run(mm_parser* p, int c):
	int n = 0
	while (mm_peek(p) == c):
		p.pos = p.pos + 1
		n = n + 1
	return n

# Closing half of a solid/thick link (`--+[-xo>]`, `==+[=xo>]`); sets the length.
int mm_flow_close(mm_parser* p, mm_edge* e, int c, int text):
	int start = p.pos
	int n = mm_flow_run(p, c)
	if (n < 2):
		p.pos = start
		return 0
	if (mm_flow_end_marker(p, e)): e.extra_rank = n - 2
	else if (n >= 3): e.extra_rank = n - 3
	else if (text == 0):
		p.pos = start
		return 0
	else: e.extra_rank = 0
	if (e.extra_rank > 16): mm_error(p.doc, start, c"link length limit exceeded")
	return 1

# Dotted closing `-?.+-[xo>]?`; the number of dots is the length.
int mm_flow_dotted_close(mm_parser* p, mm_edge* e):
	int start = p.pos
	if (mm_peek(p) == '-' && mm_flow_at(p, 1) == '.'): p.pos = p.pos + 1
	int dots = mm_flow_run(p, '.')
	if (dots == 0 || mm_peek(p) != '-'):
		p.pos = start
		return 0
	p.pos = p.pos + 1
	mm_flow_end_marker(p, e)
	e.extra_rank = dots - 1
	if (e.extra_rank > 16): mm_error(p.doc, start, c"link length limit exceeded")
	return 1

# Text between an opening `--`/`==`/`-.` and its closing link.
int mm_flow_link_text(mm_parser* p, mm_edge* e, int kind):
	mm_space(p)
	int start = p.pos
	while (mm_peek(p) != 0 && mm_peek(p) != 10):
		int at = p.pos
		int ok = 0
		if (kind == 0 && mm_peek(p) == '-' && mm_flow_at(p, 1) == '-'): ok = mm_flow_close(p, e, '-', 1)
		else if (kind == 1 && mm_peek(p) == '=' && mm_flow_at(p, 1) == '='): ok = mm_flow_close(p, e, '=', 1)
		else if (kind == 2 && (mm_peek(p) == '.' || (mm_peek(p) == '-' && mm_flow_at(p, 1) == '.'))): ok = mm_flow_dotted_close(p, e)
		if (ok):
			free(e.label)
			if (p.doc.source[start] == '"'):
				int saved = p.pos
				p.pos = start
				e.label = mm_quoted(p)
				p.pos = saved
			else: e.label = mm_style_trim(p.doc.source, start, at)
			return 1
		p.pos = at + 1
	mm_error(p.doc, start, c"expected closing link after edge text")
	return 0

# Full flowchart link grammar; returns 0 without consuming input when no link starts here.
int mm_flow_link(mm_parser* p, mm_edge* e):
	int start = p.pos
	int c = mm_peek(p)
	int next = mm_flow_at(p, 1)
	if ((c == '<' || c == 'o' || c == 'x') && (next == '-' || next == '=')):
		e.left_marker = MM_ARROW
		if (c == 'o'): e.left_marker = MM_FLOW_CIRCLE
		if (c == 'x'): e.left_marker = MM_FLOW_CROSS
		p.pos = p.pos + 1
		c = next
	if (c == '~' && e.left_marker == 0):
		int n = mm_flow_run(p, '~')
		if (n < 3):
			p.pos = start
			return 0
		e.stroke = 2
		e.extra_rank = n - 3
		if (e.extra_rank > 16): mm_error(p.doc, start, c"link length limit exceeded")
		return 1
	if (c == '='):
		e.stroke = 1
		if (mm_flow_close(p, e, '=', 0)): return 1
		if (mm_match(p, c"==")): return mm_flow_link_text(p, e, 1)
	else if (c == '-' && mm_flow_at(p, 1) == '.'):
		e.dashed = 1
		if (mm_flow_dotted_close(p, e)): return 1
		p.pos = p.pos + 2
		return mm_flow_link_text(p, e, 2)
	else if (c == '-'):
		if (mm_flow_close(p, e, '-', 0)): return 1
		if (mm_match(p, c"--")): return mm_flow_link_text(p, e, 0)
	p.pos = start
	e.left_marker = 0
	e.stroke = 0
	e.dashed = 0
	return 0
