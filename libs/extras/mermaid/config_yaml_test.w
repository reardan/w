# wbuild: x64
# Full YAML frontmatter (lists, block scalars, anchors, merges, escapes),
# directives anywhere, precedence, ignored keys and their bounds.
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* yaml_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0):
		println2(source)
		println2(d.error)
	asserts(c"configuration parses", d.error == 0)
	char* saved = mm_write(d)
	assert_strings_equal(source, saved)
	free(saved)
	return d

void yaml_reject(char* source, char* message):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error == 0 || strcmp(d.error, message) != 0):
		println2(source)
		if (d.error != 0): println2(d.error)
	asserts(c"configuration diagnosed", d.error != 0)
	if (d.error != 0): assert_strings_equal(message, d.error)
	asserts(c"no preview after configuration error", mm_render(d) == 0)
	mm_document_free(d)

void yaml_value(mm_document* d, char* key, char* expected):
	char* value = mm_config_value(d, key)
	if (value == 0):
		println2(key)
		asserts(c"configured value present", 0)
		return
	assert_strings_equal(expected, value)

int yaml_ignored(mm_document* d, char* path):
	if (d.config_ignored == 0): return 0
	for char* ignored in d.config_ignored:
		if (strcmp(ignored, path) == 0): return 1
	return 0

void test_yaml_block_and_flow_lists():
	mm_document* d = yaml_parse(c"---\nconfig:\n  timeline:\n    sectionFills:\n      - '#ff0000'\n      - green   # comment\n      - \"#00f\"\n---\ntimeline\nA : b\n")
	assert_equal(3, mm_config_count(d, c"timeline.sectionFills"))
	yaml_value(d, c"timeline.sectionFills.0", c"#ff0000")
	yaml_value(d, c"timeline.sectionFills.1", c"green")
	yaml_value(d, c"timeline.sectionFills.2", c"#00f")
	mm_document_free(d)
	# Compact sequences at the key's indentation, and flow lists over lines.
	d = yaml_parse(c"---\nconfig:\n  timeline:\n    sectionFills:\n    - red\n    - blue\n    disableMulticolor: false\n---\ntimeline\nA : b\n")
	assert_equal(2, mm_config_count(d, c"timeline.sectionFills"))
	yaml_value(d, c"timeline.disableMulticolor", c"false")
	mm_document_free(d)
	d = yaml_parse(c"---\nconfig:\n  timeline: {sectionFills: [red,\n      '#0f0', blue], width: 200}\n---\ntimeline\nA : b\n")
	assert_equal(3, mm_config_count(d, c"timeline.sectionFills"))
	yaml_value(d, c"timeline.sectionFills.1", c"#0f0")
	yaml_value(d, c"timeline.width", c"200")
	mm_document_free(d)
	# Lists of mappings are read (and ignored when no family uses them).
	d = yaml_parse(c"---\nconfig:\n  secure:\n    - name: a\n      value: 1\n    - - nested\n      - list\n---\nflowchart LR\nA\n")
	asserts(c"list member mapping ignored", yaml_ignored(d, c"config.secure.0.name"))
	asserts(c"list member mapping keeps siblings", yaml_ignored(d, c"config.secure.0.value"))
	asserts(c"nested list item ignored", yaml_ignored(d, c"config.secure.1.1"))
	mm_document_free(d)
	# A later list replaces an earlier one as a whole.
	d = yaml_parse(c"---\nconfig:\n  timeline:\n    sectionFills: [red, green, blue]\n---\n%%{init: {'timeline': {'sectionFills': ['#123']}}}%%\ntimeline\nA : b\n")
	assert_equal(1, mm_config_count(d, c"timeline.sectionFills"))
	yaml_value(d, c"timeline.sectionFills.0", c"#123")
	mm_document_free(d)

void test_yaml_block_scalars():
	mm_document* d = yaml_parse(c"---\ntitle: |\n  First line\n  second line\n\nconfig:\n  gantt:\n    axisFormat: >-\n      %Y-%m\n      %d\n---\ngantt\ndateFormat YYYY-MM-DD\nA : 2024-01-01, 1d\n")
	assert_strings_equal(c"First line\nsecond line\n", d.title)
	yaml_value(d, c"gantt.axisFormat", c"%Y-%m %d")
	mm_document_free(d)
	d = yaml_parse(c"---\ntitle: >\n  folded\n  text\n\n  next paragraph\n    more indented\nconfig: {}\n---\nflowchart LR\nA\n")
	assert_strings_equal(c"folded text\nnext paragraph\n  more indented\n", d.title)
	mm_document_free(d)
	d = yaml_parse(c"---\ntitle: |+\n  keep\n\n\nconfig: {}\n---\nflowchart LR\nA\n")
	assert_strings_equal(c"keep\n\n\n", d.title)
	mm_document_free(d)
	d = yaml_parse(c"---\ntitle: |2-\n    indented\n  base\n---\nflowchart LR\nA\n")
	assert_strings_equal(c"  indented\nbase", d.title)
	mm_document_free(d)
	d = yaml_parse(c"---\ntitle: |\n  # not a comment\nconfig: {}\n---\nflowchart LR\nA\n")
	assert_strings_equal(c"# not a comment\n", d.title)
	mm_document_free(d)

void test_yaml_quoted_strings_and_escapes():
	mm_document* d = yaml_parse(c"---\ntitle: \"Tab\\there \\\"q\\\" \\u00e9\\x41 \\U0001F600\"\nconfig:\n  sankey:\n    prefix: 'it''s '\n    suffix: \" \\\\ \"\n---\nflowchart LR\nA\n")
	assert_strings_equal(c"Tab\there \"q\" \xc3\xa9A \xf0\x9f\x98\x80", d.title)
	yaml_value(d, c"sankey.prefix", c"it's ")
	yaml_value(d, c"sankey.suffix", c" \\ ")
	mm_document_free(d)
	d = yaml_parse(c"%%{init: {\"sankey\": {\"prefix\": \"\\u0024\", 'suffix': '%'}}}%%\nflowchart LR\nA\n")
	yaml_value(d, c"sankey.prefix", c"$")
	yaml_value(d, c"sankey.suffix", c"%")
	mm_document_free(d)
	# Quoted keys may hold spaces; plain keys may too (both are just ignored here).
	d = yaml_parse(c"---\nconfig:\n  \"odd key\": 1\n  plain key: 2\n---\nflowchart LR\nA\n")
	asserts(c"quoted key", yaml_ignored(d, c"config.odd key"))
	asserts(c"plain key with space", yaml_ignored(d, c"config.plain key"))
	mm_document_free(d)

void test_yaml_anchors_aliases_and_merges():
	mm_document* d = yaml_parse(c"---\ndefaults: &axis\n  showLabel: false\n  showTitle: false\nconfig:\n  xyChart:\n    xAxis: *axis\n    yAxis:\n      <<: *axis\n      showTitle: true\n---\nxychart\nx-axis [a, b]\nbar [1, 2]\n")
	yaml_value(d, c"xyChart.xAxis.showLabel", c"false")
	yaml_value(d, c"xyChart.xAxis.showTitle", c"false")
	yaml_value(d, c"xyChart.yAxis.showLabel", c"false")
	yaml_value(d, c"xyChart.yAxis.showTitle", c"true")
	asserts(c"top-level helper keys are ignored", yaml_ignored(d, c"defaults.showLabel"))
	mm_document_free(d)
	# Scalar anchors, flow aliases and the first merge winning over a later one.
	d = yaml_parse(c"---\ncolor: &c '#abcdef'\na: &a {nodeWidth: 30, nodePadding: 5}\nb: &b {nodeWidth: 40, showValues: false}\nconfig:\n  sankey:\n    <<: [*a, *b]\n    linkColor: *c\n  timeline: {sectionFills: [*c, *c]}\n---\nflowchart LR\nA\n")
	yaml_value(d, c"sankey.nodeWidth", c"30")
	yaml_value(d, c"sankey.nodePadding", c"5")
	yaml_value(d, c"sankey.showValues", c"false")
	yaml_value(d, c"sankey.linkColor", c"#abcdef")
	yaml_value(d, c"timeline.sectionFills.1", c"#abcdef")
	mm_document_free(d)
	# Billion laughs: each alias copies entries, so expansion hits the entry limit.
	string_builder* text = string_from(c"---\na0: &a0 [x, x, x, x, x, x, x, x]\n")
	for i in range(1, 9):
		string_append(text, c"a")
		string_append_int(text, i)
		string_append(text, c": &a")
		string_append_int(text, i)
		string_append(text, c" [*a")
		string_append_int(text, i - 1)
		for k in range(7):
			string_append(text, c", *a")
			string_append_int(text, i - 1)
		string_append(text, c"]\n")
	string_append(text, c"---\nflowchart LR\nA\n")
	d = mm_parse(text.data, text.length)
	assert_strings_equal(c"configuration entry limit exceeded", d.error)
	mm_document_free(d)
	string_free(text)
	yaml_reject(c"---\nconfig:\n  theme: *missing\n---\nflowchart LR\nA\n", c"unknown YAML alias")
	yaml_reject(c"---\nx: &x dark\nconfig:\n  <<: *x\n---\nflowchart LR\nA\n", c"merge key requires a mapping alias")
	yaml_reject(c"---\nconfig:\n  <<: dark\n---\nflowchart LR\nA\n", c"merge key requires an alias")
	yaml_reject(c"---\nx: &x dark\nconfig:\n  theme: *x trailing\n---\nflowchart LR\nA\n", c"unexpected text after YAML alias")
	yaml_reject(c"---\nconfig:\n  theme: !!str dark\n---\nflowchart LR\nA\n", c"YAML tags are not supported")
	string_builder* anchors = string_from(c"---\n")
	for i in range(70):
		string_append(anchors, c"k")
		string_append_int(anchors, i)
		string_append(anchors, c": &n")
		string_append_int(anchors, i)
		string_append(anchors, c" 1\n")
	string_append(anchors, c"---\nflowchart LR\nA\n")
	d = mm_parse(anchors.data, anchors.length)
	assert_strings_equal(c"too many YAML anchors", d.error)
	mm_document_free(d)
	string_free(anchors)

void test_directives_anywhere_and_precedence():
	# Directives after the header are read in order and skipped by the parser.
	mm_document* d = yaml_parse(c"---\nconfig:\n  theme: forest\n  sequence:\n    actorMargin: 10\n    mirrorActors: true\n---\n%%{init: {'sequence': {'actorMargin': 20}}}%%\nsequenceDiagram\nA->>B: hi\n%%{init: {'sequence': {'actorMargin': 30}}}%%\n  %%{init: {\n    'theme': 'dark'\n  }}%%\nB->>A: back\n")
	yaml_value(d, c"sequence.actorMargin", c"30")
	yaml_value(d, c"sequence.mirrorActors", c"true")
	assert_equal(3, d.theme)
	assert_equal(2, d.narrative.length)
	mm_document_free(d)
	list[char*] families = list[char*]{c"flowchart LR\nA --> B\n%%{init: {'theme': 'dark'}}%%\nB --> C\n", c"mindmap\n  root\n  %%{init: {'theme': 'dark'}}%%\n    child\n", c"railroad-ebnf-beta\nrule = \"a\" ;\n%%{init: {'theme': 'dark'}}%%\n", c"pie\n%%{init: {'theme': 'dark'}}%%\n\"A\": 1\n", c"gantt\ndateFormat YYYY-MM-DD\n%%{init: {'theme': 'dark'}}%%\nA : 2024-01-01, 1d\n", c"classDiagram\nclass A\n%%{init: {'theme': 'dark'}}%%\n", c"treeView-beta\n  a\n  %%{init: {'theme': 'dark'}}%%\n"}
	for char* source in families:
		d = yaml_parse(source)
		assert_equal(3, d.theme)
		mm_scene* s = mm_render(d)
		asserts(c"family with a body directive renders", s != 0)
		mm_scene_free(s)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, families))
	# %%{wrap}%% sets wrap; unknown directives are ignored.
	d = yaml_parse(c"%%{wrap}%%\n%%{config: {'theme': 'dark'}}%%\nsequenceDiagram\nA->>B: hi\n")
	yaml_value(d, c"wrap", c"true")
	# Neither wrap nor an ignored directive selects a theme palette.
	assert_equal(0, d.theme)
	mm_document_free(d)
	# Frontmatter displayMode is the gantt shorthand and beats config.gantt.displayMode.
	d = yaml_parse(c"---\ndisplayMode: compact\nconfig:\n  gantt:\n    displayMode: ''\n---\ngantt\ndateFormat YYYY-MM-DD\nA : 2024-01-01, 1d\n")
	yaml_value(d, c"gantt.displayMode", c"compact")
	mm_document_free(d)
	yaml_reject(c"flowchart LR\nA\n%%{init: {'theme': 'dark'}\n", c"unterminated Mermaid directive")
	yaml_reject(c"flowchart LR\nA\n%%{init: {'theme': 'dark'}}%% B\n", c"unexpected text after Mermaid directive")
	yaml_reject(c"flowchart LR\nA\n%%{init: {'theme': 'dark'}}%%\n%%{init: {'look': 'sketch'}}%%\n", c"unsupported look; supported: classic, neo, handDrawn")

void test_unknown_keys_are_ignored_deterministically():
	char* source = c"---\nunknownTop: 1\nconfig:\n  fontFamilyX: serif\n  flowchart:\n    padding: 5\n  gitGraph:\n    rotateCommitLabel: false\n  sequence:\n    hideUnusedParticipants: true\n  elk:\n    mergeEdges: true\n---\n%%{init: {'maxTextSize': 90000, 'kanban': {'bogusKey': 200}, 'packet': {'rowHeight': 40}}}%%\nflowchart LR\nA\n"
	mm_document* d = yaml_parse(source)
	list[char*] paths = list[char*]{c"unknownTop", c"config.fontFamilyX", c"config.flowchart.padding", c"config.gitGraph.rotateCommitLabel", c"config.sequence.hideUnusedParticipants", c"config.elk.mergeEdges", c"config.maxTextSize", c"config.kanban.bogusKey", c"config.packet.rowHeight"}
	assert_equal(paths.length, d.config_ignored.length)
	for i in range(paths.length): assert_strings_equal(paths[i], d.config_ignored[i])
	asserts(c"ignored keys are not stored", mm_config_value(d, c"gitGraph.rotateCommitLabel") == 0)
	mm_scene* s = mm_render(d)
	asserts(c"ignored keys still render", s != 0)
	mm_scene_free(s)
	mm_document_free(d)
	__w_list_free(cast(__w_list*, paths))

void test_typed_value_diagnostics():
	yaml_reject(c"%%{init: {'sequence': {'mirrorActors': 'yes'}}}%%\nsequenceDiagram\nA->>B: x\n", c"sequence.mirrorActors must be true or false")
	yaml_reject(c"%%{init: {'sequence': {'actorMargin': 1001}}}%%\nsequenceDiagram\nA->>B: x\n", c"sequence.actorMargin must be an integer from 0 to 1000")
	yaml_reject(c"%%{init: {'sequence': {'actorMargin': 1.5}}}%%\nsequenceDiagram\nA->>B: x\n", c"sequence.actorMargin must be an integer from 0 to 1000")
	yaml_reject(c"%%{init: {'sequence': {'messageAlign': 'middle'}}}%%\nsequenceDiagram\nA->>B: x\n", c"sequence.messageAlign must be one of: left, center, right")
	yaml_reject(c"%%{init: {'radar': {'curveTension': 2}}}%%\nradar-beta\naxis a, b, c\ncurve x{1,2,3}\n", c"radar.curveTension must be a number from 0 to 1")
	yaml_reject(c"%%{init: {'gantt': {'tickInterval': 'weekly'}}}%%\ngantt\nA : 2024-01-01, 1d\n", c"gantt.tickInterval must be a count and unit such as 1day, 2week or 6hour")
	yaml_reject(c"%%{init: {'railroad': {'terminalFill': 'url(x)'}}}%%\nrailroad-ebnf-beta\na = \"b\" ;\n", c"railroad.terminalFill requires #RGB, #RRGGBB or a supported color name")
	yaml_reject(c"%%{init: {'sankey': {'linkColor': 'rainbow'}}}%%\nsankey\na,b,1\n", c"sankey.linkColor must be source, target, gradient or a color")
	yaml_reject(c"%%{init: {'sankey': {'nodeColors': {'a': 'nope'}}}}%%\nsankey\na,b,1\n", c"sankey.nodeColors.a requires #RGB, #RRGGBB or a supported color name")
	yaml_reject(c"%%{init: {'timeline': {'sectionFills': 'red'}}}%%\ntimeline\nA : b\n", c"timeline.sectionFills must be a list of colors")
	yaml_reject(c"%%{init: {'timeline': {'sectionFills': [{'a': 1}]}}}%%\ntimeline\nA : b\n", c"configuration value must be a scalar")
	yaml_reject(c"%%{init: {'gitGraph': {'mainBranchName': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}}}%%\ngitGraph\ncommit\n", c"gitGraph.mainBranchName is too long")
	yaml_reject(c"%%{init: {'sequence': 5}}%%\nsequenceDiagram\nA->>B: x\n", c"configuration section must be a mapping")
	yaml_reject(c"---\ndisplayMode: wide\n---\ngantt\nA : 2024-01-01, 1d\n", c"displayMode must be compact or empty")
	yaml_reject(c"---\ntitle: [a, b]\n---\nflowchart LR\nA\n", c"frontmatter title must be a scalar string")
	yaml_reject(c"---\n- a\n---\nflowchart LR\nA\n", c"frontmatter must be a mapping")
	yaml_reject(c"---\nconfig:\n  theme: |x\n---\nflowchart LR\nA\n", c"invalid YAML block scalar header")
	yaml_reject(c"---\nconfig: {a: [1, 2}\n---\nflowchart LR\nA\n", c"expected , or ] in configuration")
	yaml_reject(c"%%{init: {'theme': \"\\q\"}}%%\nflowchart LR\nA\n", c"unsupported escape in configuration string")
	yaml_reject(c"%%{init: {'theme': \"\\u00\"}}%%\nflowchart LR\nA\n", c"invalid unicode escape in configuration string")
	yaml_reject(c"%%{init: {'theme': \"\\u0001\"}}%%\nflowchart LR\nA\n", c"invalid unicode escape in configuration string")
	yaml_reject(c"%%{init: {'a.b': 1}}%%\nflowchart LR\nA\n", c"invalid configuration key")
	yaml_reject(c"---\nconfig:\n  a.b: 1\n---\nflowchart LR\nA\n", c"invalid frontmatter key")
	yaml_reject(c"%%{init: {'a': {'b': {'c': {'d': {'e': {'f': {'g': {'h': 1}}}}}}}}}%%\nflowchart LR\nA\n", c"configuration nesting too deep")

void test_yaml_prefixes_never_crash():
	char* source = c"---\ntitle: >-\n  folded\n  title\nbase: &b {nodeWidth: 30}\nconfig:\n  sankey:\n    <<: *b\n    linkColor: \"\\u0023ff0000\"\n  timeline:\n    sectionFills:\n      - red\n      - [blue]\n---\n%%{init: {'sankey': {'showValues': false}}}%%\nsankey\na,b,1\n%%{init: {'theme': 'dark'}}%%\n"
	for length in range(strlen(source) + 1):
		mm_document* d = mm_parse(source, length)
		mm_scene* scene = mm_render(d)
		if (d.error != 0): asserts(c"prefix errors suppress rendering", scene == 0)
		mm_scene_free(scene)
		mm_document_free(d)
