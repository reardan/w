# The canonical Mermaid node-shape catalogue (mermaid@12.2.0
# rendering-elements/shapes.ts) as native shape codes, shared by every family:
# flowchart `@{ shape: name }` (flowchart.w), swimlanes and the other
# catalogue users resolve names here, and the serializers print names from
# here. Codes below 100 are the bracket shapes; 100 and above are drawn by
# shapes.w (flow_shapes.w adds the flowchart label placement and the icon /
# image nodes).
import libs.extras.mermaid.model

const int MM_SHAPE_RECT = 0
const int MM_SHAPE_ROUNDED = 1
const int MM_SHAPE_CIRCLE = 2
const int MM_SHAPE_DIAMOND = 3
const int MM_SHAPE_FRAMED = 22
const int MM_SHAPE_STADIUM = 21
const int MM_SHAPE_HEXAGON = 23
const int MM_SHAPE_LEAN_RIGHT = 24
const int MM_SHAPE_LEAN_LEFT = 25
const int MM_SHAPE_TRAP_BOTTOM = 26
const int MM_SHAPE_TRAP_TOP = 27
const int MM_SHAPE_CYLINDER = 100
const int MM_SHAPE_DOUBLE_CIRCLE = 101
const int MM_SHAPE_ODD = 102
const int MM_SHAPE_DOCUMENT = 103
const int MM_SHAPE_LINED_DOCUMENT = 104
const int MM_SHAPE_DOCUMENTS = 105
const int MM_SHAPE_PROCESSES = 106
const int MM_SHAPE_CARD = 107
const int MM_SHAPE_LINED_RECT = 108
const int MM_SHAPE_SMALL_CIRCLE = 109
const int MM_SHAPE_FRAMED_CIRCLE = 110
const int MM_SHAPE_FORK = 111
const int MM_SHAPE_HOURGLASS = 112
const int MM_SHAPE_BRACE_LEFT = 113
const int MM_SHAPE_BRACE_RIGHT = 114
const int MM_SHAPE_BRACES = 115
const int MM_SHAPE_BOLT = 116
const int MM_SHAPE_DELAY = 117
const int MM_SHAPE_H_CYLINDER = 118
const int MM_SHAPE_LINED_CYLINDER = 119
const int MM_SHAPE_CURVED_TRAP = 120
const int MM_SHAPE_DIVIDED_RECT = 121
const int MM_SHAPE_TRIANGLE = 122
const int MM_SHAPE_WINDOW_PANE = 123
const int MM_SHAPE_FILLED_CIRCLE = 124
const int MM_SHAPE_NOTCH_PENTAGON = 125
const int MM_SHAPE_FLIPPED_TRIANGLE = 126
const int MM_SHAPE_SLOPED_RECT = 127
const int MM_SHAPE_BOW_RECT = 128
const int MM_SHAPE_CROSSED_CIRCLE = 129
const int MM_SHAPE_TAGGED_DOCUMENT = 130
const int MM_SHAPE_TAGGED_RECT = 131
const int MM_SHAPE_FLAG = 132
const int MM_SHAPE_TEXT = 133
const int MM_SHAPE_DATA_STORE = 134
const int MM_SHAPE_FOLDER = 135
const int MM_SHAPE_BUCKET = 136
const int MM_SHAPE_CONSOLE = 137
const int MM_SHAPE_BROWSER = 138
const int MM_SHAPE_PERSON = 139
const int MM_SHAPE_BANG = 140
const int MM_SHAPE_CLOUD = 141
const int MM_SHAPE_COLLAPSED = 142
const int MM_SHAPE_LAST = 142
# Flowchart icon and image nodes (`@{ icon: ... }`, `@{ img: ... }`); they have
# no shape name and are drawn by flow_shapes.w.
const int MM_SHAPE_ICON = 143
const int MM_SHAPE_IMAGE = 144

# Every short name and alias of a documented shape, `|`-separated, in the
# same order as the codes they resolve to (mm_shape_codes). The first name of
# an entry is the canonical one the serializers print.
list[char*] mm_shape_words():
	return list[char*]{c"|rect|proc|process|rectangle|squareRect|square|", c"|rounded|event|roundedRect|", c"|stadium|terminal|pill|", c"|fr-rect|subprocess|subproc|framed-rectangle|subroutine|", c"|cyl|db|database|cylinder|", c"|circle|circ|", c"|diam|decision|diamond|question|", c"|hex|hexagon|prepare|", c"|lean-r|lean-right|in-out|lean_right|", c"|lean-l|lean-left|out-in|lean_left|", c"|trap-b|priority|trapezoid-bottom|trapezoid|trapezoid-base-bottom|", c"|trap-t|manual|trapezoid-top|inv-trapezoid|inv_trapezoid|trapezoid-base-top|", c"|dbl-circ|double-circle|doublecircle|", c"|text|", c"|notch-rect|card|notched-rectangle|", c"|lin-rect|lined-rectangle|lined-process|lin-proc|shaded-process|", c"|sm-circ|start|small-circle|stateStart|", c"|fr-circ|stop|framed-circle|stateEnd|", c"|fork|join|forkJoin|", c"|hourglass|collate|", c"|brace|comment|brace-l|", c"|brace-r|", c"|braces|", c"|bolt|com-link|lightning-bolt|", c"|doc|document|", c"|delay|half-rounded-rectangle|", c"|h-cyl|das|horizontal-cylinder|", c"|lin-cyl|disk|lined-cylinder|", c"|curv-trap|curved-trapezoid|display|", c"|div-rect|div-proc|divided-rectangle|divided-process|", c"|tri|extract|triangle|", c"|win-pane|internal-storage|window-pane|", c"|f-circ|junction|filled-circle|", c"|notch-pent|loop-limit|notched-pentagon|trapezoidal-pentagon|", c"|flip-tri|manual-file|flipped-triangle|", c"|sl-rect|manual-input|sloped-rectangle|", c"|docs|documents|st-doc|stacked-document|", c"|st-rect|procs|processes|stacked-rectangle|", c"|bow-rect|stored-data|bow-tie-rectangle|", c"|cross-circ|summary|crossed-circle|", c"|tag-doc|tagged-document|", c"|tag-rect|tagged-rectangle|tag-proc|tagged-process|", c"|flag|paper-tape|", c"|odd|rect_left_inv_arrow|", c"|lin-doc|lined-document|", c"|datastore|data-store|", c"|folder|directory|", c"|bucket|", c"|console|", c"|browser|", c"|person|", c"|bang|", c"|cloud|", c"|collapsedGroup|"}

list[int] mm_shape_codes():
	return list[int]{0, 1, 21, 22, 100, 2, 3, 23, 24, 25, 26, 27, 101, 133, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 103, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 105, 106, 128, 129, 130, 131, 132, 102, 104, 134, 135, 136, 137, 138, 139, 140, 141, 142}

# The shape code of a name or alias; -1 when unknown.
int mm_shape_lookup(char* name):
	if (name == 0 || name[0] == 0 || strlen(name) > 40): return -1
	list[char*] words = mm_shape_words()
	list[int] codes = mm_shape_codes()
	string_builder* needle = string_from(c"|")
	string_append(needle, name)
	string_append_char(needle, '|')
	int result = -1
	for i in range(words.length):
		if (result < 0 && index_of(words[i], needle.data) >= 0): result = codes[i]
	string_free(needle)
	__w_list_free(cast(__w_list*, words))
	__w_list_free(cast(__w_list*, codes))
	return result

# The canonical (first) name of a shape code, newly allocated; 0 for codes
# without a name.
char* mm_shape_name(int code):
	list[char*] words = mm_shape_words()
	list[int] codes = mm_shape_codes()
	char* result = 0
	for i in range(words.length):
		if (result == 0 && codes[i] == code):
			char* entry = words[i]
			int end = 1
			while (entry[end] != '|'): end = end + 1
			result = substring(entry, 1, end)
	__w_list_free(cast(__w_list*, words))
	__w_list_free(cast(__w_list*, codes))
	return result

# Whether a code is one of the named catalogue shapes drawn by shapes.w.
int mm_shape_catalogued(int shape):
	return shape >= MM_SHAPE_CYLINDER && shape <= MM_SHAPE_LAST
