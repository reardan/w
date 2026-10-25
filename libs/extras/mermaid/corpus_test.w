# wbuild: name=mermaid_corpus_test deps=tests/mermaid_corpus/ deps=docs/projects/mermaid_compatibility.md
# wbuild: target=mermaid_corpus_update dep=wv2
# wbuild: step="bin/wv2 libs/extras/mermaid/corpus_test.w -o bin/mermaid_corpus_update"
# wbuild: step="bin/mermaid_corpus_update --update"
/*
Pinned upstream Mermaid conformance corpus (issue #821).

tests/mermaid_corpus/index.txt lists every example extracted from the pinned
upstream syntax docs by tools/mermaid_corpus_extract.py. manifest.txt records,
one tab-separated line per example,

	<path>	<class>	<observed>[	<note>]

where <class> is supported, partial or unsupported and <observed> is what
the library does with the example through the same read/parse path as the
`wmermaid` CLI (mm_read: frontmatter, %%{init}%% and Markdown fences
included), then mm_render and mm_svg:

	ok                   parses, renders a non-empty scene and an SVG
	noscene / empty      parses, but renders no scene / an empty scene
	nosvg                renders, but SVG export fails
	error <diagnostic>   rejected; the manifest text must be a substring
	                     of the actual "line:column: message" diagnostic

Class follows from <observed>: error is unsupported, noscene/empty/nosvg is
partial, ok is supported -- unless the entry is marked partial with a note
recording a known difference, which is kept. The test fails on every drift
in either direction (regressions and newly accepted examples alike), on
index/manifest disagreement, and when the generated per-family counts in
docs/projects/mermaid_compatibility.md are stale.

`--update` (`./wbuild mermaid_corpus_update`) rewrites manifest.txt from
current behavior, keeping notes and still-matching diagnostic substrings,
and regenerates the docs counts block.
*/
import lib.args
import lib.str
import libs.extras.mermaid.io
import libs.extras.mermaid.render

struct mc_entry:
	char* path
	char* family
	char* cls
	char* observed
	char* note

void mc_print_int(int v):
	string_builder* s = string_new()
	string_append_int(s, v)
	print(s.data)
	string_free(s)

char* mc_dir():
	return c"tests/mermaid_corpus/"

char* mc_doc_path():
	return c"docs/projects/mermaid_compatibility.md"

char* mc_begin_marker():
	return c"<!-- corpus-counts:begin -->"

char* mc_end_marker():
	return c"<!-- corpus-counts:end -->"

char* mc_join(char* a, char* b):
	string_builder* s = string_from(a)
	string_append(s, b)
	char* text = s.data
	free(s)
	return text

# Whole small text file, or null when unreadable / over the 1 MiB budget.
char* mc_read_text(char* path):
	int length = 0
	char* data = mm_read_source(path, &length)
	if (data == 0): return 0
	char* text = str_copy_range(data, 0, length)
	free(data)
	return text

list[char*] mc_split(char* text, int sep):
	list[char*] out = new list[char*]
	int length = strlen(text)
	int start = 0
	for i in range(length + 1):
		if (i == length || text[i] == sep):
			out.push(str_copy_range(text, start, i))
			start = i + 1
	return out

# Data lines of a corpus table: blank lines and # comments are skipped.
list[list[char*]] mc_read_table(char* path):
	list[list[char*]] rows = new list[list[char*]]
	char* text = mc_read_text(path)
	if (text == 0): return rows
	list[char*] lines = mc_split(text, '\n')
	for char* line in lines:
		if (line[0] == 0 || line[0] == '#'): continue
		rows.push(mc_split(line, '\t'))
	free(text)
	return rows

char* mc_family(char* path):
	int slash = index_of(path, c"/")
	if (slash < 0): return strclone(c"other")
	return str_copy_range(path, 0, slash)

char* mc_clean(char* text):
	char* out = strclone(text)
	int i = 0
	while (out[i] != 0):
		if (out[i] == '\t' || out[i] == '\n' || out[i] == '\r'): out[i] = ' '
		i = i + 1
	return out

char* mc_observe(char* rel):
	char* path = mc_join(mc_dir(), rel)
	mm_document* d = mm_read(path)
	free(path)
	if (d == 0): return strclone(c"error cannot read input (I/O failure or 1 MiB limit)")
	char* result = 0
	if (d.error != 0):
		char* diagnostic = mm_diagnostic(d)
		char* clean = mc_clean(diagnostic)
		result = mc_join(c"error ", clean)
		free(clean)
		free(diagnostic)
	else:
		mm_scene* scene = mm_render(d)
		if (scene == 0): result = strclone(c"noscene")
		else if (scene.items.length == 0): result = strclone(c"empty")
		else:
			char* svg = mm_svg(scene)
			if (svg == 0 || index_of(svg, c"<svg") < 0): result = strclone(c"nosvg")
			else: result = strclone(c"ok")
			if (svg != 0): free(svg)
		if (scene != 0): mm_scene_free(scene)
	mm_document_free(d)
	return result

int mc_is_error(char* observed):
	return starts_with(observed, c"error ")

# Does the manifest's recorded observation still describe `actual`?
int mc_matches(char* recorded, char* actual):
	if (mc_is_error(recorded) && mc_is_error(actual)): return index_of(actual, &recorded[6]) >= 0
	return strcmp(recorded, actual) == 0

char* mc_class_for(char* observed, char* recorded_class, char* note):
	if (mc_is_error(observed)): return c"unsupported"
	if (strcmp(observed, c"ok") == 0):
		if (recorded_class != 0 && strcmp(recorded_class, c"partial") == 0 && note != 0 && note[0] != 0): return c"partial"
		return c"supported"
	return c"partial"

int mc_rank(char* cls):
	if (strcmp(cls, c"supported") == 0): return 2
	if (strcmp(cls, c"partial") == 0): return 1
	return 0

char* mc_field(list[char*] row, int i):
	if (i < row.length): return row[i]
	return c""

char* mc_counts_block(list[mc_entry*] entries):
	list[char*] families = new list[char*]
	map[char*, int] slot = new map[char*, int]
	list[int] counts = new list[int]
	for mc_entry* e in entries:
		if (!(e.family in slot)):
			slot[e.family] = families.length
			families.push(e.family)
			for k in range(4): counts.push(0)
	int[4] all
	for k in range(4): all[k] = 0
	for mc_entry* e in entries:
		int at = slot[e.family] * 4
		int r = 2 - mc_rank(e.cls)
		counts[at + r] = counts[at + r] + 1
		counts[at + 3] = counts[at + 3] + 1
		all[r] = all[r] + 1
		all[3] = all[3] + 1
	string_builder* s = string_new()
	string_append(s, c"\n\n| Family | Supported | Partial | Unsupported | Total |\n| --- | ---: | ---: | ---: | ---: |\n")
	# Alphabetical rows: insertion sort of family slots by name.
	list[int] order = new list[int]
	for i in range(families.length):
		order.push(i)
		int j = order.length - 1
		while (j > 0 && strcmp(families[order[j - 1]], families[order[j]]) > 0):
			int swap = order[j]
			order[j] = order[j - 1]
			order[j - 1] = swap
			j = j - 1
	for int i in order:
		string_append(s, c"| ")
		string_append(s, families[i])
		for k in range(4):
			string_append(s, c" | ")
			string_append_int(s, counts[i * 4 + k])
		string_append(s, c" |\n")
	string_append(s, c"| **All** ")
	for k in range(4):
		string_append(s, c"| **")
		string_append_int(s, all[k])
		string_append(s, c"** ")
	string_append(s, c"|\n\n")
	char* text = s.data
	free(s)
	return text

# The doc text between the markers, or null when a marker is missing.
char* mc_doc_block(char* doc):
	int begin = index_of(doc, mc_begin_marker())
	int end = index_of(doc, mc_end_marker())
	if (begin < 0 || end < begin): return 0
	return str_copy_range(doc, begin + strlen(mc_begin_marker()), end)

int mc_write(char* path, char* text):
	io_result result
	return file_write_durable(path, text, strlen(text), &result) == IO_OK

int mc_update(list[mc_entry*] entries):
	string_builder* s = string_new()
	string_append(s, c"# Mermaid conformance corpus classifications; see README.md.\n")
	string_append(s, c"# Regenerate with ./wbuild mermaid_corpus_update (keeps notes and\n")
	string_append(s, c"# still-matching diagnostic substrings).\n")
	string_append(s, c"# path<TAB>class<TAB>observed[<TAB>note]\n")
	for mc_entry* e in entries:
		string_append(s, e.path)
		string_append_char(s, '\t')
		string_append(s, e.cls)
		string_append_char(s, '\t')
		string_append(s, e.observed)
		if (e.note[0] != 0):
			string_append_char(s, '\t')
			string_append(s, e.note)
		string_append_char(s, '\n')
	char* manifest_path = mc_join(mc_dir(), c"manifest.txt")
	if (!mc_write(manifest_path, s.data)):
		println2(c"mermaid_corpus_update: cannot write manifest")
		return 1
	char* doc = mc_read_text(mc_doc_path())
	if (doc == 0 || mc_doc_block(doc) == 0):
		println2(c"mermaid_corpus_update: docs/projects/mermaid_compatibility.md lacks the corpus-counts markers")
		return 1
	int begin = index_of(doc, mc_begin_marker()) + strlen(mc_begin_marker())
	int end = index_of(doc, mc_end_marker())
	string_builder* out = string_new()
	string_append_bytes(out, doc, begin)
	char* block = mc_counts_block(entries)
	string_append(out, block)
	string_append(out, &doc[end])
	if (!mc_write(mc_doc_path(), out.data)):
		println2(c"mermaid_corpus_update: cannot write the compatibility doc")
		return 1
	print(c"mermaid_corpus_update: wrote ")
	print(manifest_path)
	print(c" (")
	mc_print_int(entries.length)
	println(c" examples) and the counts block")
	return 0

int main(int argc, int argv):
	args_init(argc, argv)
	int update = argc >= 2 && strcmp(args_get(1), c"--update") == 0
	list[list[char*]] index = mc_read_table(mc_join(mc_dir(), c"index.txt"))
	list[list[char*]] manifest = mc_read_table(mc_join(mc_dir(), c"manifest.txt"))
	if (index.length == 0):
		println2(c"mermaid_corpus_test: tests/mermaid_corpus/index.txt is missing or empty (run tools/mermaid_corpus_extract.py)")
		return 1
	map[char*, int] recorded = new map[char*, int]
	for i in range(manifest.length): recorded[manifest[i][0]] = i
	map[char*, int] indexed = new map[char*, int]
	list[mc_entry*] entries = new list[mc_entry*]
	list[char*] problems = new list[char*]
	for list[char*] row in index:
		mc_entry* e = new mc_entry()
		e.path = row[0]
		indexed[e.path] = 1
		e.family = mc_family(e.path)
		char* actual = mc_observe(e.path)
		char* old_class = 0
		e.note = c""
		e.observed = actual
		if (e.path in recorded):
			list[char*] old = manifest[recorded[e.path]]
			old_class = mc_field(old, 1)
			e.note = mc_field(old, 3)
			char* old_observed = mc_field(old, 2)
			if (mc_matches(old_observed, actual)):
				e.observed = old_observed
				char* expected = mc_class_for(actual, old_class, e.note)
				if (strcmp(expected, old_class) != 0):
					problems.push(mc_join(mc_join(mc_join(c"CLASS      ", e.path), c": manifest class is inconsistent with its observation; expected "), expected))
			else:
				char* now = mc_class_for(actual, old_class, e.note)
				char* kind = c"CHANGED    "
				if (mc_rank(now) < mc_rank(old_class)): kind = c"REGRESSION "
				else if (mc_rank(now) > mc_rank(old_class)): kind = c"IMPROVED   "
				string_builder* m = string_from(kind)
				string_append(m, e.path)
				string_append(m, c": manifest `")
				string_append(m, old_observed)
				string_append(m, c"` but now `")
				string_append(m, actual)
				string_append(m, c"`")
				problems.push(m.data)
		else: problems.push(mc_join(mc_join(c"UNRECORDED ", e.path), c": example has no manifest entry"))
		e.cls = mc_class_for(e.observed, old_class, e.note)
		entries.push(e)
	for list[char*] row in manifest:
		if (!(row[0] in indexed)): problems.push(mc_join(mc_join(c"STALE      ", row[0]), c": manifest entry is not in index.txt"))
	if (update): return mc_update(entries)
	char* doc = mc_read_text(mc_doc_path())
	char* block = 0
	if (doc != 0): block = mc_doc_block(doc)
	if (block == 0 || strcmp(block, mc_counts_block(entries)) != 0):
		problems.push(c"DOC        docs/projects/mermaid_compatibility.md: the corpus-counts block is missing or stale")
	int[3] totals
	for k in range(3): totals[k] = 0
	for mc_entry* e in entries: totals[mc_rank(e.cls)] = totals[mc_rank(e.cls)] + 1
	print(c"mermaid corpus: ")
	mc_print_int(entries.length)
	print(c" examples, ")
	mc_print_int(totals[2])
	print(c" supported, ")
	mc_print_int(totals[1])
	print(c" partial, ")
	mc_print_int(totals[0])
	println(c" unsupported")
	if (problems.length == 0):
		println(c"mermaid_corpus_test OK")
		return 0
	for char* p in problems: println(p)
	mc_print_int(problems.length)
	println(c" corpus mismatch(es). REGRESSION entries are bugs to fix. For intended changes")
	println(c"(IMPROVED/CHANGED/UNRECORDED/STALE/DOC) run `./wbuild mermaid_corpus_update`, review the")
	println(c"diff of tests/mermaid_corpus/manifest.txt and docs/projects/mermaid_compatibility.md, and commit it.")
	println(c"A `partial` entry whose example now renders keeps its class only with a note (4th field).")
	return 1
