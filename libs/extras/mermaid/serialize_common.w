# Shared emitters for the per-family canonical serializers: quoting, colors,
# style properties, accessibility lines and the YAML frontmatter that carries
# a document's resolved configuration (theme, theme variables, fonts, layout,
# spacing and every validated per-family key). Family serializers set
# out.failed instead of emitting text the parsers would read differently.
import libs.extras.mermaid.parser
import libs.extras.mermaid.serialize_equal

struct mm_serializer:
	string_builder* text
	int failed
	int nodes
	int edges
	list[int] edge_order
	# Current indentation depth of block-structured output (one tab per level
	# is never used: Mermaid indents with spaces, two per level).
	int depth

void mm_out(mm_serializer* out, char* text):
	string_append(out.text, text)

void mm_out_char(mm_serializer* out, int c):
	string_append_char(out.text, c)

void mm_out_int(mm_serializer* out, int value):
	string_append_int(out.text, value)

void mm_out_line(mm_serializer* out):
	string_append_char(out.text, 10)

void mm_out_indent(mm_serializer* out):
	for i in range(out.depth): string_append(out.text, c"  ")

# Text that must stay on one line and must not contain the given terminators.
void mm_out_plain(mm_serializer* out, char* text, char* forbidden):
	if (text == 0):
		out.failed = 1
		return
	for i in range(strlen(text)):
		int c = text[i] & 255
		if (c == 10 || c == 13): out.failed = 1
		if (forbidden != 0):
			for k in range(strlen(forbidden)):
				if (c == (forbidden[k] & 255)): out.failed = 1
		string_append_char(out.text, c)

void mm_serialize_quote(mm_serializer* out, char* text):
	if (text == 0):
		out.failed = 1
		return
	string_append_char(out.text, '"')
	for i in range(strlen(text)):
		int c = text[i] & 255
		if (c == '"' || c < 32): out.failed = 1
		string_append_char(out.text, c)
	string_append_char(out.text, '"')

# A flowchart label in quotes; a Markdown string ("`...`") may span lines.
void mm_serialize_flow_label(mm_serializer* out, char* text):
	if (text == 0):
		out.failed = 1
		return
	int length = strlen(text)
	int markdown = length >= 2 && text[0] == '`' && text[length - 1] == '`'
	string_append_char(out.text, '"')
	for i in range(length):
		int c = text[i] & 255
		if (c == '"' || (c < 32 && (markdown == 0 || c != 10))): out.failed = 1
		string_append_char(out.text, c)
	string_append_char(out.text, '"')

# Whole text is an identifier the shared mm_identifier reads unquoted.
int mm_serialize_is_id(char* text):
	if (text == 0 || text[0] == 0): return 0
	for i in range(strlen(text)):
		if (mm_id_char(text[i] & 255) == 0): return 0
	return 1

# An identifier position: bare when possible, quoted otherwise.
void mm_serialize_id(mm_serializer* out, char* text):
	if (mm_serialize_is_id(text)): mm_out(out, text)
	else: mm_serialize_quote(out, text)

void mm_serialize_color(mm_serializer* out, int color):
	if (color == -1):
		string_append(out.text, c"none")
		return
	if (color < 0 || color > 16777215): out.failed = 1
	string_append_char(out.text, '#')
	char* digits = c"0123456789abcdef"
	for i in range(6): string_append_char(out.text, digits[(color >> ((5 - i) * 4)) & 15])

void mm_serialize_comma(mm_serializer* out, int* comma):
	if (*comma): string_append_char(out.text, ',')
	*comma = 1

# Hundredths as a CSS alpha value ("0.5", "1", "0.05").
void mm_serialize_alpha(mm_serializer* out, int value):
	if (value < 0 || value > 100): out.failed = 1
	if (value == 100):
		mm_out(out, c"1")
		return
	mm_out(out, c"0.")
	mm_out_char(out, '0' + value / 10)
	if (value % 10): mm_out_char(out, '0' + value % 10)

# Every property a mask bit selects, without a trailing newline.
void mm_serialize_style_properties(mm_serializer* out, mm_document* d, mm_style* style):
	int known = MM_STYLE_FILL | MM_STYLE_STROKE | MM_STYLE_TEXT | MM_STYLE_WIDTH | MM_STYLE_DASH | MM_STYLE_OPACITY | MM_STYLE_WEIGHT | MM_STYLE_ITALIC | MM_STYLE_SIZE | MM_STYLE_FAMILY | MM_STYLE_RADIUS | MM_STYLE_FILL_OPACITY
	if (style.mask < 1 || (style.mask & known) != style.mask): out.failed = 1
	int comma = 0
	int m = style.mask
	if (m & MM_STYLE_FILL):
		mm_serialize_comma(out, &comma)
		mm_out(out, c"fill:")
		mm_serialize_color(out, style.fill)
	if (m & MM_STYLE_STROKE):
		mm_serialize_comma(out, &comma)
		mm_out(out, c"stroke:")
		mm_serialize_color(out, style.stroke)
	if (m & MM_STYLE_TEXT):
		mm_serialize_comma(out, &comma)
		mm_out(out, c"color:")
		mm_serialize_color(out, style.text)
	if (m & MM_STYLE_WIDTH):
		mm_serialize_comma(out, &comma)
		mm_out(out, c"stroke-width:")
		if (style.width < 1 || style.width > 16): out.failed = 1
		mm_out_int(out, style.width)
		mm_out(out, c"px")
	if (m & MM_STYLE_DASH):
		mm_serialize_comma(out, &comma)
		mm_out(out, c"stroke-dasharray:")
		if (style.dash == 0): mm_out(out, c"0")
		else:
			if (style.dash < 1 || style.dash > 64 || style.gap < 1 || style.gap > 64): out.failed = 1
			mm_out_int(out, style.dash)
			mm_out_char(out, 32)
			mm_out_int(out, style.gap)
	if (m & MM_STYLE_OPACITY):
		mm_serialize_comma(out, &comma)
		mm_out(out, c"opacity:")
		mm_serialize_alpha(out, style.opacity)
	if (m & MM_STYLE_WEIGHT):
		mm_serialize_comma(out, &comma)
		if (style.font & MM_TEXT_BOLD): mm_out(out, c"font-weight:bold")
		else: mm_out(out, c"font-weight:normal")
	if (m & MM_STYLE_ITALIC):
		mm_serialize_comma(out, &comma)
		if (style.font & MM_TEXT_ITALIC): mm_out(out, c"font-style:italic")
		else: mm_out(out, c"font-style:normal")
	if (m & MM_STYLE_SIZE):
		mm_serialize_comma(out, &comma)
		mm_out(out, c"font-size:")
		mm_out_int(out, style.font_size)
		mm_out(out, c"px")
	if (m & MM_STYLE_FAMILY):
		mm_serialize_comma(out, &comma)
		mm_out(out, c"font-family:")
		if (style.family < 1 || style.family > d.style_fonts.length): out.failed = 1
		else: mm_out_plain(out, d.style_fonts[style.family - 1], c",;:")
	if (m & MM_STYLE_RADIUS):
		mm_serialize_comma(out, &comma)
		mm_out(out, c"rx:")
		mm_out_int(out, style.radius)
		mm_out(out, c"px")
	if (m & MM_STYLE_FILL_OPACITY):
		mm_serialize_comma(out, &comma)
		mm_out(out, c"fill-opacity:")
		mm_serialize_alpha(out, style.fill_opacity)

void mm_serialize_style(mm_serializer* out, mm_document* d, mm_style* style):
	mm_serialize_style_properties(out, d, style)
	mm_out_line(out)

# `classDef` lines for every style class, in definition order.
void mm_serialize_class_defs(mm_serializer* out, mm_document* d):
	for mm_style_class* definition in d.style_definitions:
		mm_out_indent(out)
		mm_out(out, c"classDef ")
		if (mm_style_name(definition.name) == 0): out.failed = 1
		mm_out(out, definition.name)
		mm_out_char(out, 32)
		mm_serialize_style(out, d, &definition.style)

# `style ID ...` and `class ID ...` for one node.
void mm_serialize_node_style(mm_serializer* out, mm_document* d, mm_node* n):
	if (n.style.mask == 0 && n.style_classes[0] == 0): return
	if (mm_style_name(n.id) == 0): out.failed = 1
	if (n.style.mask != 0):
		mm_out_indent(out)
		mm_out(out, c"style ")
		mm_out(out, n.id)
		mm_out_char(out, 32)
		mm_serialize_style(out, d, &n.style)
	if (n.style_classes[0] != 0):
		mm_out_indent(out)
		mm_out(out, c"class ")
		mm_out(out, n.id)
		mm_out_char(out, 32)
		mm_out_plain(out, n.style_classes, c";%")
		mm_out_line(out)

# accTitle / accDescr for parsers that read mm_metadata.
void mm_serialize_accessibility(mm_serializer* out, mm_document* d):
	if (d.accessibility_title[0] != 0):
		mm_out_indent(out)
		mm_out(out, c"accTitle: ")
		mm_out_plain(out, d.accessibility_title, c";")
		mm_out_line(out)
	char* description = d.accessibility_description
	if (description[0] != 0):
		mm_out_indent(out)
		if (index_of(description, c"\n") < 0 && index_of(description, c";") < 0 && index_of(description, c"}") < 0):
			mm_out(out, c"accDescr: ")
			mm_out(out, description)
			mm_out_line(out)
		else:
			if (index_of(description, c"}") >= 0): out.failed = 1
			mm_out(out, c"accDescr {")
			mm_out(out, description)
			mm_out(out, c"\n")
			mm_out_indent(out)
			mm_out(out, c"}\n")

# ---- Legacy node/edge comparisons (edit_commands.w) ----

# Compare the semantics we promise to serialize, not just syntactic validity.
# This also rejects tokens mutated into statement injections by model callers.
int mm_serialize_text_equal(char* a, char* b):
	if (a == 0): a = c""
	if (b == 0): b = c""
	return strcmp(a, b) == 0

int mm_serialize_style_equal(mm_style* a, mm_style* b):
	if (a.mask != b.mask): return 0
	if ((a.mask & MM_STYLE_FILL) && a.fill != b.fill): return 0
	if ((a.mask & MM_STYLE_STROKE) && a.stroke != b.stroke): return 0
	if ((a.mask & MM_STYLE_TEXT) && a.text != b.text): return 0
	if ((a.mask & MM_STYLE_WIDTH) && a.width != b.width): return 0
	return 1

# State start/end pseudo-states are identified as "@start:<scope index>". Returns
# the prefix length (and the scope through *scope) or 0 for any other identifier.
int mm_serialize_pseudo(char* id, int* scope):
	int length = 0
	if (starts_with(id, c"@start:")): length = 7
	else if (starts_with(id, c"@end:")): length = 5
	if (length == 0): return 0
	int at = length
	int sign = 1
	if (id[at] == '-'):
		sign = -1
		at = at + 1
	int value = 0
	if (id[at] == 0): return 0
	while (id[at] >= '0' && id[at] <= '9' && value < MM_MAX_ITEMS):
		value = value * 10 + id[at] - '0'
		at = at + 1
	if (id[at] != 0): return 0
	*scope = sign * value
	return length

# Node references compare by identity. A pseudo-state's identity is its kind
# plus its composite's identity, since edits may shift the composite's index.
int mm_serialize_reference_equal(mm_document* a, int ai, mm_document* b, int bi):
	if (ai == -1 || bi == -1): return ai == bi
	if (ai < 0 || ai >= a.nodes.length || bi < 0 || bi >= b.nodes.length): return 0
	int a_scope = 0
	int b_scope = 0
	int a_prefix = mm_serialize_pseudo(a.nodes[ai].id, &a_scope)
	int b_prefix = mm_serialize_pseudo(b.nodes[bi].id, &b_scope)
	if (a_prefix != 0 && a_prefix == b_prefix && a_scope >= 0 && b_scope >= 0 && a_scope < ai && b_scope < bi): return mm_serialize_reference_equal(a, a_scope, b, b_scope)
	return mm_serialize_text_equal(a.nodes[ai].id, b.nodes[bi].id)

# The node of b with the same identity as a.nodes[index], or -1.
int mm_serialize_find_equal(mm_document* a, int index, mm_document* b):
	int scope = 0
	int prefix = mm_serialize_pseudo(a.nodes[index].id, &scope)
	if (prefix == 0 || scope < 0 || scope >= index): return mm_find_node(b, a.nodes[index].id)
	int other = mm_serialize_find_equal(a, scope, b)
	if (other < 0): return -1
	string_builder* key = string_new()
	string_append_bytes(key, a.nodes[index].id, prefix)
	string_append_int(key, other)
	int found = mm_find_node(b, key.data)
	string_free(key)
	return found

int mm_serialize_node_equal(mm_node* a, mm_node* b):
	if (mm_serialize_text_equal(a.label, b.label) == 0 || a.shape != b.shape || a.group != b.group): return 0
	if (mm_serialize_text_equal(a.direction, b.direction) == 0 || mm_serialize_text_equal(a.style_classes, b.style_classes) == 0): return 0
	if (mm_serialize_style_equal(&a.style, &b.style) == 0): return 0
	if (a.attributes.length != b.attributes.length): return 0
	for i in range(a.attributes.length):
		mm_attribute* left = a.attributes[i]
		mm_attribute* right = b.attributes[i]
		if (mm_serialize_text_equal(left.type_name, right.type_name) == 0 || mm_serialize_text_equal(left.name, right.name) == 0): return 0
		if (mm_serialize_text_equal(left.keys, right.keys) == 0 || mm_serialize_text_equal(left.comment, right.comment) == 0): return 0
	# Family-specific model state must not silently disappear.
	if (a.value_x != b.value_x || a.value_y != b.value_y || a.declared != b.declared || a.global_node != b.global_node): return 0
	if (mm_serialize_text_equal(a.annotation, b.annotation) == 0 || mm_serialize_text_equal(a.role, b.role) == 0): return 0
	if (a.members.length != b.members.length || a.metadata.length != b.metadata.length): return 0
	# Metadata pairs compare in order; a label pair follows the node label itself.
	for i in range(a.metadata.length):
		mm_property* left = a.metadata[i]
		mm_property* right = b.metadata[i]
		if (strcmp(left.key, right.key) != 0): return 0
		if (strcmp(left.key, c"label") != 0 && mm_serialize_text_equal(left.value, right.value) == 0): return 0
	if (mm_serialize_text_equal(a.link, b.link) == 0 || mm_serialize_text_equal(a.link_target, b.link_target) == 0): return 0
	if (mm_serialize_text_equal(a.tooltip, b.tooltip) == 0 || mm_serialize_text_equal(a.callback, b.callback) == 0): return 0
	return 1

int mm_serialize_edge_equal(mm_document* a, mm_edge* left, mm_document* b, mm_edge* right):
	if (mm_serialize_reference_equal(a, left.from_node, b, right.from_node) == 0 || mm_serialize_reference_equal(a, left.to_node, b, right.to_node) == 0): return 0
	if (mm_serialize_reference_equal(a, left.scope, b, right.scope) == 0): return 0
	if (mm_serialize_text_equal(left.label, right.label) == 0 || mm_serialize_text_equal(left.left_label, right.left_label) == 0 || mm_serialize_text_equal(left.right_label, right.right_label) == 0): return 0
	if (left.dashed != right.dashed || left.arrow != right.arrow || left.left_card != right.left_card || left.right_card != right.right_card): return 0
	if (left.from_port != right.from_port || left.to_port != right.to_port || left.left_marker != right.left_marker || left.right_marker != right.right_marker): return 0
	if (mm_serialize_text_equal(left.id, right.id) == 0 || left.stroke != right.stroke || left.extra_rank != right.extra_rank || left.animate != right.animate || left.curve != right.curve): return 0
	return mm_serialize_style_equal(&left.style, &right.style)

# ---- Frontmatter ----

struct mm_serialize_pair:
	char* key
	char* value

# themeVariables name of a resolved theme variable index.
char* mm_serialize_theme_name(int index):
	list[char*] names = list[char*]{c"background", c"primaryColor", c"primaryBorderColor", c"primaryTextColor", c"secondaryColor", c"secondaryBorderColor", c"secondaryTextColor", c"tertiaryColor", c"tertiaryBorderColor", c"tertiaryTextColor", c"lineColor", c"textColor", c"mainBkg", c"nodeBorder", c"clusterBkg", c"clusterBorder", c"titleColor", c"edgeLabelBackground"}
	list[char*] extras = list[char*]{c"noteBkgColor", c"noteBorderColor", c"noteTextColor", c"actorBkg", c"actorBorder", c"actorTextColor", c"actorLineColor", c"signalColor", c"signalTextColor", c"git0", c"git1", c"git2", c"git3", c"git4", c"git5", c"git6", c"git7", c"venn1", c"venn2", c"venn3", c"venn4", c"venn5", c"venn6", c"venn7", c"venn8", c"taskBkgColor", c"taskBorderColor", c"taskTextColor", c"activeTaskBkgColor", c"doneTaskBkgColor", c"critBkgColor", c"gridColor", c"todayLineColor", c"sectionBkgColor", c"altSectionBkgColor", c"excludeBkgColor", c"attributeBackgroundColorOdd", c"attributeBackgroundColorEven", c"gradientStart", c"gradientStop"}
	string_builder* s = string_new()
	if (index < names.length): string_append(s, names[index])
	else if (index < MM_THEME_SCALE):
		string_append(s, c"pie")
		string_append_int(s, index - MM_THEME_PIE + 1)
	else if (index < MM_THEME_NOTE_BKG):
		string_append(s, c"cScale")
		string_append_int(s, index - MM_THEME_SCALE)
	else if (index - MM_THEME_NOTE_BKG < extras.length): string_append(s, extras[index - MM_THEME_NOTE_BKG])
	__w_list_free(cast(__w_list*, names))
	__w_list_free(cast(__w_list*, extras))
	char* result = s.data
	free(s)
	return result

char* mm_serialize_theme_id_name(int theme):
	list[char*] names = list[char*]{c"default", c"base", c"dark", c"forest", c"neutral", c"neo", c"neo-dark", c"redux", c"redux-dark", c"redux-color", c"redux-dark-color"}
	char* result = 0
	if (theme >= 1 && theme <= names.length): result = names[theme - 1]
	__w_list_free(cast(__w_list*, names))
	return result

void mm_serialize_pair_add(list[mm_serialize_pair*] pairs, char* key, char* value):
	mm_serialize_pair* pair = new mm_serialize_pair()
	pair.key = strclone(key)
	pair.value = strclone(value)
	pairs.push(pair)

char* mm_serialize_hex(int color):
	string_builder* s = string_from(c"#")
	char* digits = c"0123456789abcdef"
	for i in range(6): string_append_char(s, digits[(color >> ((5 - i) * 4)) & 15])
	char* result = s.data
	free(s)
	return result

# The fewest explicit theme variables (in index order) that resolve to the
# document's palette: start from none and pin every variable that differs
# until the resolution matches.
void mm_serialize_theme_pairs(mm_serializer* out, mm_document* d, list[mm_serialize_pair*] pairs):
	if (d.theme_values == 0 || d.theme_values.length != MM_THEME_COUNT):
		out.failed = 1
		return
	list[int] user = new list[int]
	for i in range(MM_THEME_COUNT): user.push(MM_THEME_UNSET)
	int done = 0
	int rounds = 0
	while (done == 0 && rounds <= MM_THEME_COUNT):
		mm_document* scratch = mm_document_new()
		mm_style_theme_resolve(scratch, d.theme, user, -1)
		done = 1
		for i in range(MM_THEME_COUNT):
			if (scratch.theme_values[i] != d.theme_values[i] && user[i] == MM_THEME_UNSET):
				user[i] = d.theme_values[i]
				done = 0
		mm_document_free(scratch)
		rounds = rounds + 1
	if (done == 0): out.failed = 1
	for i in range(MM_THEME_COUNT):
		if (user[i] == MM_THEME_UNSET): continue
		if (user[i] < 0 || user[i] > 16777215):
			out.failed = 1
			continue
		char* name = mm_serialize_theme_name(i)
		string_builder* key = string_from(c"themeVariables.")
		string_append(key, name)
		char* color = mm_serialize_hex(user[i])
		mm_serialize_pair_add(pairs, key.data, color)
		free(color)
		free(name)
		string_free(key)
	__w_list_free(cast(__w_list*, user))

# A resolved configuration key the YAML reader stores itself; other keys in
# the document's configuration come from diagram statements (timeline TD,
# Wardley size) that the family serializer writes back.
int mm_serialize_config_stored(char* key):
	char* spec = mm_config_spec(key)
	if (spec != 0):
		free(spec)
		return 1
	int dot = rindex_of(key, c".")
	if (dot <= 0): return 0
	char* parent = str_copy_range(key, 0, dot)
	spec = mm_config_spec(parent)
	free(parent)
	if (spec == 0): return 0
	int kind = spec[0]
	free(spec)
	return kind == 'L' || kind == 'M' || kind == 'N'

int mm_serialize_list_parent(char* key):
	char* spec = mm_config_spec(key)
	if (spec == 0): return 0
	int list = spec[0] == 'L'
	free(spec)
	return list

void mm_serialize_yaml_string(mm_serializer* out, char* value):
	mm_out_char(out, '"')
	for i in range(strlen(value)):
		int c = value[i] & 255
		if (c == '"' || c == '\\'):
			mm_out_char(out, '\\')
			mm_out_char(out, c)
		else if (c == 10): mm_out(out, c"\\n")
		else if (c == 9): mm_out(out, c"\\t")
		else if (c == 13): mm_out(out, c"\\r")
		else if (c < 32): out.failed = 1
		else: mm_out_char(out, c)
	mm_out_char(out, '"')

void mm_serialize_yaml_spaces(mm_serializer* out, int indent):
	for i in range(indent): mm_out_char(out, 32)

# The segment of key after prefix ("" or "a.b.") up to the next dot, or null
# when key is not below prefix.
char* mm_serialize_segment(char* key, char* prefix):
	int length = strlen(prefix)
	if (starts_with(key, prefix) == 0): return 0
	int end = length
	while (key[end] != 0 && key[end] != '.'): end = end + 1
	if (end == length): return 0
	return str_copy_range(key, length, end)

# Nested YAML for every pair below prefix, grouped by first appearance.
void mm_serialize_yaml_level(mm_serializer* out, list[mm_serialize_pair*] pairs, char* prefix, int indent):
	if (indent > 40):
		out.failed = 1
		return
	list[char*] seen = new list[char*]
	for mm_serialize_pair* pair in pairs:
		char* segment = mm_serialize_segment(pair.key, prefix)
		if (segment == 0): continue
		int repeated = 0
		for char* other in seen:
			if (strcmp(other, segment) == 0): repeated = 1
		if (repeated):
			free(segment)
			continue
		seen.push(segment)
		string_builder* full = string_from(prefix)
		string_append(full, segment)
		mm_serialize_yaml_spaces(out, indent)
		if (index_of(segment, c"\x1f") >= 0):
			# A literal dot inside a member key (`.ts:`), stored as MM_CONFIG_KEY_DOT.
			char* dotted = strclone(segment)
			for i in range(strlen(dotted)):
				if (dotted[i] == MM_CONFIG_KEY_DOT): dotted[i] = '.'
			mm_serialize_yaml_string(out, dotted)
			free(dotted)
		else if (mm_serialize_is_id(segment) == 0 && index_of(segment, c"-") < 0): mm_serialize_yaml_string(out, segment)
		else: mm_out(out, segment)
		mm_out_char(out, ':')
		char* scalar = 0
		for mm_serialize_pair* candidate in pairs:
			if (strcmp(candidate.key, full.data) == 0): scalar = candidate.value
		if (scalar != 0):
			mm_out_char(out, 32)
			mm_serialize_yaml_string(out, scalar)
			mm_out_line(out)
		else:
			mm_out_line(out)
			string_append_char(full, '.')
			string_builder* parent = string_from(prefix)
			string_append(parent, segment)
			char* config_key = parent.data
			if (index_of(config_key, c"config.") == 0): config_key = config_key + 7
			if (mm_serialize_list_parent(config_key)):
				for i in range(MM_MAX_ITEMS):
					string_builder* item = string_from(full.data)
					string_append_int(item, i)
					char* value = 0
					for mm_serialize_pair* candidate in pairs:
						if (strcmp(candidate.key, item.data) == 0): value = candidate.value
					string_free(item)
					if (value == 0): break
					mm_serialize_yaml_spaces(out, indent + 2)
					mm_out(out, c"- ")
					mm_serialize_yaml_string(out, value)
					mm_out_line(out)
			else: mm_serialize_yaml_level(out, pairs, full.data, indent + 2)
			string_free(parent)
		string_free(full)
	for char* segment in seen: free(segment)
	__w_list_free(cast(__w_list*, seen))

# Synthesized pairs for configuration resolved into document fields, then
# every stored per-family value. css_classes asks for the style classes as
# themeCSS (families without a classDef statement).
void mm_serialize_frontmatter(mm_serializer* out, mm_document* d, int css_classes):
	list[mm_serialize_pair*] pairs = new list[mm_serialize_pair*]
	# Data charts and railroad grammars carry their own title statement.
	int own_title = (d.data != 0 && strcmp(d.title, d.data.title) == 0) || (d.railroad != 0 && strcmp(d.title, d.railroad.title) == 0)
	if (d.title[0] != 0 && own_title == 0): mm_serialize_pair_add(pairs, c"title", d.title)
	if (d.theme != 0):
		char* name = mm_serialize_theme_id_name(d.theme)
		if (name == 0): out.failed = 1
		else: mm_serialize_pair_add(pairs, c"config.theme", name)
	else if (d.theme_values != 0 || d.look != 0 || d.layout_algorithm != 0 || d.edge_curve != 0 || d.packet_bits != 32 || d.packet_msb != 0 || d.ticket_base_url != 0): out.failed = 1
	if (d.look == 1): mm_serialize_pair_add(pairs, c"config.look", c"neo")
	else if (d.look != 0): out.failed = 1
	if (d.layout_algorithm == 1): mm_serialize_pair_add(pairs, c"config.layout", c"force")
	else if (d.layout_algorithm == 2): mm_serialize_pair_add(pairs, c"config.layout", c"elk")
	else if (d.layout_algorithm != 0): out.failed = 1
	if (d.font_family != 0): mm_serialize_pair_add(pairs, c"config.fontFamily", d.font_family)
	if (d.font_size != 0):
		string_builder* size = string_new()
		string_append_int(size, d.font_size)
		mm_serialize_pair_add(pairs, c"config.fontSize", size.data)
		string_free(size)
	if (css_classes && d.style_definitions.length != 0):
		mm_serializer css
		css.text = string_new()
		css.failed = 0
		css.depth = 0
		for mm_style_class* definition in d.style_definitions:
			if (mm_style_name(definition.name) == 0): out.failed = 1
			mm_out_char(&css, '.')
			mm_out(&css, definition.name)
			mm_out(&css, c" { ")
			mm_serialize_style_properties(&css, d, &definition.style)
			mm_out(&css, c" } ")
		char* rules = replace(css.text.data, c",", c"; ")
		mm_serialize_pair_add(pairs, c"config.themeCSS", rules)
		free(rules)
		if (css.failed): out.failed = 1
		string_free(css.text)
	if (d.theme != 0):
		list[mm_serialize_pair*] theme = new list[mm_serialize_pair*]
		mm_serialize_theme_pairs(out, d, theme)
		for mm_serialize_pair* pair in theme:
			string_builder* key = string_from(c"config.")
			string_append(key, pair.key)
			mm_serialize_pair_add(pairs, key.data, pair.value)
			string_free(key)
			free(pair.key)
			free(pair.value)
			free(pair)
		__w_list_free(cast(__w_list*, theme))
	# Flowchart spacing keys select the default palette; the use case and
	# architecture sections set the same spacing without one.
	char* node_key = c"config.flowchart.nodeSpacing"
	char* rank_key = c"config.flowchart.rankSpacing"
	if (d.theme == 0 && d.kind == MM_USECASE):
		node_key = c"config.usecase.nodeSpacing"
		rank_key = c"config.usecase.rankSpacing"
	else if (d.theme == 0 && d.kind == MM_ARCHITECTURE):
		node_key = c"config.architecture.nodeSeparation"
		rank_key = 0
	if (d.config_mask & 1):
		string_builder* spacing = string_new()
		string_append_int(spacing, d.node_spacing)
		mm_serialize_pair_add(pairs, node_key, spacing.data)
		string_free(spacing)
	if (d.config_mask & 2):
		if (rank_key == 0): out.failed = 1
		else:
			string_builder* spacing = string_new()
			string_append_int(spacing, d.rank_spacing)
			mm_serialize_pair_add(pairs, rank_key, spacing.data)
			string_free(spacing)
	if (d.config_mask < 0 || d.config_mask > 3): out.failed = 1
	if (d.edge_curve == 1): mm_serialize_pair_add(pairs, c"config.flowchart.curve", c"linear")
	else if (d.edge_curve == 2): mm_serialize_pair_add(pairs, c"config.flowchart.curve", c"basis")
	else if (d.edge_curve != 0): out.failed = 1
	if (d.packet_bits != 32):
		string_builder* bits = string_new()
		string_append_int(bits, d.packet_bits)
		mm_serialize_pair_add(pairs, c"config.packet.bitsPerRow", bits.data)
		string_free(bits)
	if (d.packet_msb): mm_serialize_pair_add(pairs, c"config.packet.bitOrder", c"descending")
	if (d.ticket_base_url != 0): mm_serialize_pair_add(pairs, c"config.kanban.ticketBaseUrl", d.ticket_base_url)
	if (d.usecase_rotate): mm_serialize_pair_add(pairs, c"config.usecase.colorScheme", c"rotate")
	if (d.config != 0):
		for mm_property* property in d.config:
			if (mm_serialize_config_stored(property.key) == 0): continue
			string_builder* key = string_from(c"config.")
			string_append(key, property.key)
			mm_serialize_pair_add(pairs, key.data, property.value)
			string_free(key)
	if (pairs.length != 0):
		mm_out(out, c"---\n")
		mm_serialize_yaml_level(out, pairs, c"", 0)
		mm_out(out, c"---\n")
	for mm_serialize_pair* pair in pairs:
		free(pair.key)
		free(pair.value)
		free(pair)
	__w_list_free(cast(__w_list*, pairs))
