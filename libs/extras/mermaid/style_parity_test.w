# wbuild: x64
# Styling and theme parity fixtures: one per supported CSS property, font
# option, theme and theme variable, one per family styling form, and the
# deliberately unsupported options that must fail with a diagnostic.
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* parity_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0):
		println2(source)
		println2(d.error)
	asserts(c"styling fixture parses", d.error == 0)
	char* saved = mm_write(d)
	assert_strings_equal(source, saved)
	free(saved)
	return d

# Render source to SVG and require needle in it.
void parity_svg(char* source, char* needle):
	mm_document* d = parity_parse(source)
	mm_scene* s = mm_render(d)
	asserts(c"styled fixture renders", s != 0)
	char* svg = mm_svg(s)
	if (index_of(svg, needle) < 0):
		println2(source)
		println2(needle)
	asserts(c"styled fixture SVG carries the expected attribute", index_of(svg, needle) >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void parity_reject(char* source, char* message):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error == 0 || strcmp(d.error, message) != 0):
		println2(source)
		if (d.error != 0): println2(d.error)
	assert_strings_equal(message, d.error)
	asserts(c"rejected fixture has no preview", mm_render(d) == 0)
	mm_document_free(d)

void test_style_every_css_property():
	list[char*] properties = list[char*]{c"fill:#ff0000", c"stroke:#00ff00", c"color:#0000ff", c"stroke-width:3px", c"stroke-dasharray:5 3", c"opacity:0.5", c"fill-opacity:0.25", c"font-weight:bold", c"font-style:italic", c"font-size:20px", c"font-family:Georgia", c"rx:6", c"ry:7"}
	list[char*] needles = list[char*]{c"fill=\"#ff0000\"", c"stroke=\"#00ff00\"", c"fill=\"#0000ff\"", c"stroke-width=\"3\"", c"stroke-dasharray=\"5 3\"", c"opacity=\"0.5\"", c"fill-opacity=\"0.25\"", c"font-weight=\"bold\"", c"font-style=\"italic\"", c"font-size=\"20\"", c"font-family=\"Georgia\"", c"rx=\"6\"", c"rx=\"7\""}
	for i in range(properties.length):
		# Each property through style, classDef + class, and classDef + :::.
		list[char*] forms = list[char*]{c"flowchart LR\nA[Node]\nstyle A ", c"flowchart LR\nA[Node]\nclass A c\nclassDef c ", c"flowchart LR\nA[Node]:::c\nclassDef c "}
		for char* form in forms:
			char* source = strjoin(strjoin(form, properties[i]), c"\n")
			parity_svg(source, needles[i])
		__w_list_free(cast(__w_list*, forms))
	__w_list_free(cast(__w_list*, properties))
	__w_list_free(cast(__w_list*, needles))

void test_style_theme_css_and_fonts():
	parity_svg(c"---\nconfig:\n  themeCSS: \".hot { fill: #ff0000 !important; stroke-width: 4px; }\"\n---\nflowchart LR\nA:::hot\n", c"stroke-width=\"4\"")
	parity_svg(c"---\nconfig:\n  themeCSS: \".a, .b { color: #123456 } /* note */ .c { font-weight: bold }\"\n---\nflowchart LR\nA:::b\nB:::c\n", c"fill=\"#123456\"")
	parity_svg(c"---\nconfig:\n  fontFamily: Georgia, serif\n---\nflowchart LR\nA\n", c"font-family=\"Georgia, serif\"")
	parity_svg(c"---\nconfig:\n  fontSize: 20\n---\nflowchart LR\nA\n", c"font-size=\"20\"")
	parity_svg(c"---\nconfig:\n  themeVariables:\n    fontFamily: Courier\n---\nflowchart LR\nA\n", c"font-family=\"Courier\"")
	parity_svg(c"---\nconfig:\n  themeVariables:\n    fontSize: 12px\n---\nflowchart LR\nA\n", c"font-size=\"12\"")
	# A larger font measures larger: the node grows with the label.
	mm_document* small = parity_parse(c"---\nconfig:\n  fontSize: 10\n---\nflowchart LR\nA[Measured label]\n")
	mm_document* large = parity_parse(c"---\nconfig:\n  fontSize: 30\n---\nflowchart LR\nA[Measured label]\n")
	mm_scene* a = mm_render(small)
	mm_scene* b = mm_render(large)
	mm_bounds* first = a.nodes[0]
	mm_bounds* second = b.nodes[0]
	asserts(c"fontSize drives text metrics", second.h > first.h)
	mm_scene_free(a)
	mm_scene_free(b)
	mm_document_free(small)
	mm_document_free(large)

void test_style_every_theme_and_look():
	list[char*] themes = list[char*]{c"default", c"base", c"dark", c"forest", c"neutral", c"neo", c"neo-dark", c"redux", c"redux-dark", c"redux-color", c"redux-dark-color"}
	for i in range(themes.length):
		char* source = strjoin(strjoin(c"---\nconfig:\n  theme: ", themes[i]), c"\n---\nflowchart LR\nA --> B\n")
		mm_document* d = parity_parse(source)
		assert_equal(i + 1, d.theme)
		mm_document_free(d)
		parity_svg(strjoin(strjoin(c"---\nconfig:\n  look: neo\n  theme: ", themes[i]), c"\n---\nflowchart LR\nA --> B\n"), c"filter=\"url(#mermaid-drop-shadow)\"")
	__w_list_free(cast(__w_list*, themes))
	parity_svg(c"---\nconfig:\n  look: neo\n  theme: neo\n---\nflowchart LR\nA\n", c"<linearGradient id=\"mermaid-gradient\"")

void test_style_every_theme_variable():
	list[char*] names = list[char*]{c"background", c"primaryColor", c"primaryBorderColor", c"primaryTextColor", c"secondaryColor", c"secondaryBorderColor", c"secondaryTextColor", c"tertiaryColor", c"tertiaryBorderColor", c"tertiaryTextColor", c"lineColor", c"textColor", c"mainBkg", c"nodeBorder", c"clusterBkg", c"clusterBorder", c"titleColor", c"edgeLabelBackground", c"noteBkgColor", c"noteBorderColor", c"noteTextColor", c"actorBkg", c"actorBorder", c"actorTextColor", c"actorLineColor", c"signalColor", c"signalTextColor", c"taskBkgColor", c"taskBorderColor", c"taskTextColor", c"activeTaskBkgColor", c"doneTaskBkgColor", c"critBkgColor", c"gridColor", c"todayLineColor", c"sectionBkgColor", c"altSectionBkgColor", c"excludeBkgColor", c"attributeBackgroundColorOdd", c"attributeBackgroundColorEven", c"gradientStart", c"gradientStop"}
	for i in range(8): names.push(strjoin(c"git", itoa(i)))
	for i in range(1, 9): names.push(strjoin(c"venn", itoa(i)))
	for i in range(1, 13): names.push(strjoin(c"pie", itoa(i)))
	for i in range(12): names.push(strjoin(c"cScale", itoa(i)))
	assert_equal(MM_THEME_COUNT, names.length)
	for char* name in names:
		int index = mm_theme_variable(name)
		asserts(c"theme variable is known", index >= 0)
		char* source = strjoin(strjoin(c"---\nconfig:\n  theme: base\n  themeVariables:\n    ", name), c": '#123456'\n---\nflowchart LR\nA\n")
		mm_document* d = parity_parse(source)
		assert_equal(0x123456, d.theme_values[index])
		mm_document_free(d)

void test_style_family_parity():
	char* hot = c"fill=\"#ff0000\""
	parity_svg(c"stateDiagram-v2\nA:::hot --> B\nclassDef hot fill:#ff0000\n", hot)
	parity_svg(c"stateDiagram-v2\nstate A\nclass A hot\nclassDef hot fill:#ff0000\n", hot)
	parity_svg(c"stateDiagram-v2\nA --> B\nstyle B fill:#ff0000\n", hot)
	# Mindmap and TreeView classes come from themeCSS, as upstream's CSS does.
	parity_svg(c"---\nconfig:\n  themeCSS: \".hot { fill: #ff0000; }\"\n---\nmindmap\n  root\n    A\n    :::hot\n", hot)
	parity_svg(c"---\nconfig:\n  themeCSS: \".hot { fill: #ff0000; }\"\n---\ntreeView-beta\n  src/\n    App.tsx :::hot\n", hot)
	parity_svg(c"treeView-beta\n  src/\n    App.tsx :::highlight\n", c"fill=\"#fff7dc\"")
	parity_svg(c"treemap-beta\n\"S\"\n    \"Leaf\": 3\nstyle \"Leaf\" fill:#ff0000\n", hot)
	parity_svg(c"venn-beta\nset A\nset B\nunion A,B[\"AB\"]\nstyle A,B fill:#ff0000\n", hot)
	parity_svg(c"venn-beta\nset A\nset B\nstyle A fill:#ff0000,fill-opacity:0.5\n", c"fill-opacity=\"0.5\"")
	parity_svg(c"packet-beta\n0-15: \"Port\":::hot\nclassDef hot fill:#ff0000\n", hot)
	parity_svg(c"packet-beta\n0-15: \"Port\"\nstyle 0 fill:#ff0000\n", hot)
	parity_svg(c"radar-beta\naxis a, b, c\ncurve x{1, 2, 3}\nstyle x fill:#ff0000\n", hot)
	parity_svg(c"swimlane-beta LR\nsubgraph Lane\n  a([Start]):::hot\nend\nclassDef hot fill:#ff0000\n", hot)
	parity_svg(c"swimlane-beta LR\nsubgraph Lane\n  a{Decide}\nend\nstyle a fill:#ff0000\n", hot)
	parity_svg(c"usecase-beta\nactor User\nLogin(Log in):::hot\nUser --> Login\nclassDef hot fill:#ff0000\n", hot)
	parity_svg(c"block-beta\na b\na -.-> b\n", c"stroke-dasharray=\"6 4\"")
	parity_svg(c"block-beta\na b\na ==> b\n", c"stroke-width=\"4\"")
	# Themed family roles: sequence notes take noteBkgColor.
	parity_svg(c"---\nconfig:\n  theme: base\n  themeVariables:\n    noteBkgColor: '#abcdef'\n---\nsequenceDiagram\nNote over A: hi\n", c"fill=\"#abcdef\"")
	parity_svg(c"---\nconfig:\n  theme: base\n  themeVariables:\n    git0: '#abcdef'\n---\ngitGraph\ncommit\n", c"stroke=\"#abcdef\"")

void test_style_rich_labels():
	char* bold = c"font-weight=\"bold\""
	parity_svg(c"erDiagram\nA {\nstring id \"`the **key**`\"\n}\n", bold)
	parity_svg(c"requirementDiagram\nrequirement R {\nid: 1\ntext: \"the **bold** one\"\n}\n", bold)
	parity_svg(c"journey\nsection S\n  `Make **tea**`: 5: Me\n", bold)
	parity_svg(c"timeline\n2020 : `**big** year`\n", bold)
	parity_svg(c"sequenceDiagram\nNote over A: `**bold** note`\n", bold)
	parity_svg(c"usecase-beta\nactor User\nLogin(\"`Log **in**`\")\nUser --> Login\n", bold)
	parity_svg(c"sequenceDiagram\nA->>B: one<br>two\n", c">two</text>")

void test_style_unsupported_options():
	parity_reject(c"---\nconfig:\n  look: handDrawn\n---\nflowchart LR\nA\n", c"unsupported look; supported: classic, neo")
	parity_reject(c"flowchart LR\nA\nstyle A text-shadow:1px\n", c"unsupported style property; supported: fill, stroke, color, stroke-width, stroke-dasharray, opacity, fill-opacity, font-weight, font-style, font-size, font-family, rx, ry")
	parity_reject(c"---\nconfig:\n  themeCSS: \"#A rect { fill: red }\"\n---\nflowchart LR\nA\n", c"themeCSS supports .class { property: value; } rules")
	parity_reject(c"---\nconfig:\n  themeVariables:\n    fooColor: '#123456'\n---\nflowchart LR\nA\n", c"unsupported theme variable")
	parity_reject(c"---\nconfig:\n  fontSize: 200\n---\nflowchart LR\nA\n", c"fontSize must be 8 to 72 (px)")
	parity_reject(c"treeView-beta\n  App.tsx icon(fa)\n", c"TreeView icons are not yet supported")
	parity_reject(c"stateDiagram-v2\n[*]:::hot --> A\nclassDef hot fill:red\n", c"start and end states cannot be styled")
	parity_reject(c"venn-beta\nset A\nstyle Z fill:red\n", c"style target matches no item")
