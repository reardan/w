# wbuild: x64
import lib.testing
import libs.extras.mermaid.serialize

void test_mermaid_canonical_model_edits_and_styles():
	char* source = c"%% removed comment\nflowchart LR\nclassDef warm fill:#ff0,color:#111\nsubgraph S[Scope]\ndirection TD\nA([Start]):::warm -->|go| B{{Done}}\nend\nstyle B stroke:#123456\nlinkStyle 0 stroke:red,color:blue,stroke-width:3\n"
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"original parse", d.error == 0)
	int index = mm_find_node(d, c"B")
	free(d.nodes[index].label)
	d.nodes[index].label = strclone(c"Edited model")
	char* text = mm_serialize(d)
	asserts(c"canonical output", text != 0)
	asserts(c"comments removed", index_of(text, c"removed comment") < 0)
	mm_document* result = mm_parse(text, strlen(text))
	asserts(c"canonical parses", result.error == 0)
	assert_strings_equal(c"Edited model", result.nodes[mm_find_node(result, c"B")].label)
	assert_equal(23, result.nodes[mm_find_node(result, c"B")].shape)
	assert_equal(0xff0000, result.edges[0].style.stroke)
	assert_equal(3, result.edges[0].style.width)
	assert_equal(1, result.style_definitions.length)
	assert_equal(3, result.nodes.length)
	assert_strings_equal(source, d.source)
	char* again = mm_serialize(result)
	assert_strings_equal(text, again)
	free(again)
	free(text)
	mm_document_free(result)
	mm_document_free(d)

void test_mermaid_canonical_er_attributes_and_cardinality():
	char* source = c"---\ntitle: Business schema\n---\nerDiagram\ndirection RL\naccTitle: Accessible schema\naccDescr {\nTwo entities\n}\nCustomer[Client] {\nint id PK, UK \"identifier\"\nstring name\n}\nCustomer |o..|{ Order : \"places order\"\n"
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"ER parse", d.error == 0)
	free(d.nodes[0].attributes[1].name)
	d.nodes[0].attributes[1].name = strclone(c"display_name")
	char* text = mm_serialize(d)
	asserts(c"ER output", text != 0)
	mm_document* result = mm_parse(text, strlen(text))
	asserts(c"ER reparse", result.error == 0)
	assert_strings_equal(c"display_name", result.nodes[0].attributes[1].name)
	assert_strings_equal(c"PK, UK", result.nodes[0].attributes[0].keys)
	assert_strings_equal(c"identifier", result.nodes[0].attributes[0].comment)
	assert_equal(0, result.edges[0].left_card)
	assert_equal(3, result.edges[0].right_card)
	assert_equal(1, result.edges[0].dashed)
	assert_strings_equal(c"Business schema", result.title)
	assert_strings_equal(c"Accessible schema", result.accessibility_title)
	assert_strings_equal(d.accessibility_description, result.accessibility_description)
	assert_strings_equal(c"RL", result.direction)
	free(text)
	mm_document_free(result)
	mm_document_free(d)

void test_mermaid_canonical_rejects_unsupported_or_invalid_model():
	list[char*] sources = list[char*]{c"pie\n\"A\": 1\n", c"---\nconfig:\n  theme: dark\n---\nflowchart LR\nA\n", c"flowchart LR\nA["}
	for char* source in sources:
		mm_document* d = mm_parse(source, strlen(source))
		assert_equal(0, cast(int, mm_serialize(d)))
		mm_document_free(d)
	__w_list_free(cast(__w_list*, sources))
	char* source = c"flowchart LR\nA --> B\n"
	mm_document* d = mm_parse(source, strlen(source))
	free(d.nodes[0].label)
	d.nodes[0].label = strclone(c"unrepresentable \" quote")
	assert_equal(0, cast(int, mm_serialize(d)))
	free(d.nodes[0].label)
	d.nodes[0].label = strclone(c"fine")
	d.edges[0].to_node = 1000
	assert_equal(0, cast(int, mm_serialize(d)))
	mm_document_free(d)

void test_mermaid_canonical_rejects_semantic_token_injection():
	char* source = c"erDiagram\nA {\nint id\n}\nA ||--o{ B : owns\n"
	mm_document* d = mm_parse(source, strlen(source))
	# Still one valid attribute after parsing, but no longer the requested name.
	free(d.nodes[0].attributes[0].name)
	d.nodes[0].attributes[0].name = strclone(c"id PK")
	assert_equal(0, cast(int, mm_serialize(d)))
	mm_document_free(d)
	source = c"flowchart LR\nclassDef warm fill:red\nA:::warm --> B\n"
	d = mm_parse(source, strlen(source))
	# This emits valid source without changing the node/edge counts.
	free(d.nodes[0].style_classes)
	d.nodes[0].style_classes = strclone(c"warm\nstyle A fill:blue")
	assert_equal(0, cast(int, mm_serialize(d)))
	free(d.nodes[0].style_classes)
	d.nodes[0].style_classes = strclone(c"warm")
	free(d.style_definitions[0].name)
	d.style_definitions[0].name = strclone(c"warm fill:red\nclassDef added")
	assert_equal(0, cast(int, mm_serialize(d)))
	free(d.style_definitions[0].name)
	d.style_definitions[0].name = strclone(c"warm")
	# A truthy value is not sufficient: canonical output must preserve fields.
	d.edges[0].arrow = 2
	assert_equal(0, cast(int, mm_serialize(d)))
	d.edges[0].arrow = 1
	char* text = mm_serialize(d)
	asserts(c"valid model remains serializable", text != 0)
	free(text)
	mm_document_free(d)

void test_mermaid_canonical_scoped_edge_styles_follow_output_order():
	char* source = c"flowchart LR\nOutside --> Other\nsubgraph Group[Grouped]\nInside --> Last\nend\nlinkStyle 0 stroke:red\nlinkStyle 1 stroke:blue\n"
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"scoped parse", d.error == 0)
	char* text = mm_serialize(d)
	asserts(c"scoped serialization", text != 0)
	mm_document* result = mm_parse(text, strlen(text))
	asserts(c"scoped canonical parse", result.error == 0)
	assert_strings_equal(c"Inside", result.nodes[result.edges[0].from_node].id)
	assert_equal(0x0000ff, result.edges[0].style.stroke)
	assert_strings_equal(c"Outside", result.nodes[result.edges[1].from_node].id)
	assert_equal(0xff0000, result.edges[1].style.stroke)
	free(text)
	mm_document_free(result)
	mm_document_free(d)

void test_mermaid_canonical_rejects_foreign_family_metadata():
	char* source = c"flowchart LR\nA\n"
	mm_document* d = mm_parse(source, strlen(source))
	mm_note* note = new mm_note()
	note.node = 0
	note.text = strclone(c"cannot silently omit")
	d.notes.push(note)
	assert_equal(0, cast(int, mm_serialize(d)))
	mm_document_free(d)
