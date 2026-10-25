# Canonical (semantic model -> source) serialization for every family the
# engine parses. Unlike mm_write (the lossless default for save) this
# deliberately replaces formatting and comments and emits one standalone
# diagram: YAML frontmatter with the resolved configuration, then the
# family's statements in a consistent indented layout. Each family lives in
# its own serialize_<family>.w file; this file dispatches and verifies.
# The result is reparsed and must yield the same semantic model
# (mm_document_diff); otherwise null is returned, never approximate output.
import libs.extras.mermaid.serialize_flow
import libs.extras.mermaid.serialize_uml
import libs.extras.mermaid.serialize_hierarchy
import libs.extras.mermaid.serialize_frameworks
import libs.extras.mermaid.serialize_gitgraph
import libs.extras.mermaid.serialize_blocks
import libs.extras.mermaid.serialize_architecture
import libs.extras.mermaid.serialize_usecase
import libs.extras.mermaid.serialize_c4
import libs.extras.mermaid.serialize_workflows
import libs.extras.mermaid.serialize_narrative
import libs.extras.mermaid.serialize_data
import libs.extras.mermaid.serialize_railroad

# Families whose grammar has a classDef statement; the others carry style
# classes as frontmatter themeCSS.
int mm_serialize_has_class_defs(int kind):
	return kind == MM_FLOW || kind == MM_ER || kind == MM_AGENT || kind == MM_CLASS || kind == MM_STATE || kind == MM_REQUIREMENT || kind == MM_BLOCK || kind == MM_USECASE || kind == MM_SWIMLANE || kind == MM_EVENT_MODEL || mm_serialize_data_class_defs(kind)

void mm_serialize_body(mm_serializer* out, mm_document* d, int variant):
	int kind = d.kind
	if (kind == MM_FLOW || kind == MM_ER || kind == MM_AGENT): mm_serialize_flow_body(out, d, variant)
	else if (kind == MM_CLASS || kind == MM_STATE || kind == MM_REQUIREMENT): mm_serialize_uml_body(out, d, variant)
	else if (kind == MM_MINDMAP || kind == MM_KANBAN || kind == MM_TREEVIEW || kind == MM_ISHIKAWA): mm_serialize_hierarchy_body(out, d, variant)
	else if (kind == MM_CYNEFIN || kind == MM_WARDLEY): mm_serialize_frameworks_body(out, d, variant)
	else if (kind == MM_GITGRAPH): mm_serialize_gitgraph_body(out, d, variant)
	else if (kind == MM_BLOCK): mm_serialize_blocks_body(out, d, variant)
	else if (kind == MM_ARCHITECTURE): mm_serialize_architecture_body(out, d, variant)
	else if (kind == MM_USECASE): mm_serialize_usecase_body(out, d, variant)
	else if (kind == MM_C4): mm_serialize_c4_body(out, d, variant)
	else if (kind == MM_SWIMLANE || kind == MM_EVENT_MODEL): mm_serialize_workflows_body(out, d, variant)
	else if (kind >= MM_SEQUENCE && kind <= MM_ZENUML): mm_serialize_narrative_body(out, d, variant)
	else if (kind >= MM_PIE && kind <= MM_PACKET): mm_serialize_data_body(out, d, variant)
	else if (kind >= MM_RAIL_IR && kind <= MM_RAIL_PEG): mm_serialize_railroad_body(out, d, variant)
	else: out.failed = 1

# One attempt with a family-specific variant (0 = preferred layout; flowchart
# 1 = with a node-order prelude). Owned text or null.
char* mm_serialize_attempt(mm_document* d, int variant, char** diff):
	mm_serializer out
	out.text = string_new()
	out.failed = 0
	out.nodes = 0
	out.edges = 0
	out.depth = 0
	out.edge_order = new list[int]
	mm_serialize_frontmatter(&out, d, mm_serialize_has_class_defs(d.kind) == 0)
	mm_serialize_body(&out, d, variant)
	__w_list_free(cast(__w_list*, out.edge_order))
	if (out.text.length > MM_MAX_SOURCE): out.failed = 1
	if (out.failed):
		string_free(out.text)
		if (diff != 0 && diff[0] == 0): diff[0] = strclone(c"model has no canonical source form")
		return 0
	mm_document* check = mm_parse(out.text.data, out.text.length)
	char* difference = mm_document_diff(d, check)
	mm_document_free(check)
	if (difference != 0):
		if (diff != 0):
			if (diff[0] != 0): free(diff[0])
			diff[0] = difference
		else: free(difference)
		string_free(out.text)
		return 0
	char* result = out.text.data
	free(out.text)
	return result

# Canonical source, or null; *diff (when not null) receives an owned reason.
char* mm_serialize_explain(mm_document* d, char** diff):
	if (diff != 0): diff[0] = 0
	if (d == 0):
		if (diff != 0): diff[0] = strclone(c"no document")
		return 0
	if (d.error != 0):
		if (diff != 0): diff[0] = strclone(c"document has a parse error")
		return 0
	char* text = mm_serialize_attempt(d, 0, diff)
	if (text == 0 && (d.kind == MM_FLOW || d.kind == MM_ER || d.kind == MM_AGENT)): text = mm_serialize_attempt(d, 1, diff)
	if (text != 0 && diff != 0 && diff[0] != 0):
		free(diff[0])
		diff[0] = 0
	return text

char* mm_serialize(mm_document* d):
	return mm_serialize_explain(d, 0)

# Formatting: canonical, consistently indented source for a Mermaid text,
# or null when it does not parse or has no canonical form.
char* mm_format(char* source, int length):
	mm_document* d = mm_parse(source, length)
	char* text = mm_serialize(d)
	mm_document_free(d)
	return text
