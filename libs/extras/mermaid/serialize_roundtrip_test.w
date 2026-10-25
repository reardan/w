# wbuild: x64 deps=tests/mermaid_corpus/ deps=examples/mermaid/
/*
Canonical serialization round trips (issue #816). For every diagram of
examples/mermaid/ and every parsing example of the pinned upstream corpus
(tests/mermaid_corpus/manifest.txt):

	parse -> mm_serialize -> parse yields the same semantic model
	(mm_document_diff), and serializing is idempotent:
	serialize(parse(serialize(x))) == serialize(x).

Examples that cannot round-trip are listed in mm_rt_known() with the
reason; the test fails when a listed example starts passing (remove it)
and when an unlisted one fails. MM_ROUNDTRIP_REPORT=1 prints every failure with the
first model difference instead of asserting.
*/
import lib.testing
import lib.env
import libs.standard.fs.glob
import libs.extras.mermaid.io
import libs.extras.mermaid.serialize

# path<TAB>reason for corpus examples without a canonical round trip.
char* mm_rt_known():
	return c""

char* mm_rt_join(char* a, char* b):
	string_builder* s = string_from(a)
	string_append(s, b)
	char* text = s.data
	free(s)
	return text

int mm_rt_reporting():
	char* value = env_get(c"MM_ROUNDTRIP_REPORT")
	return value != 0 && value[0] == '1'

# Null when the diagram round-trips, else an owned description.
char* mm_rt_check(mm_document* d):
	if (d == 0): return strclone(c"unreadable")
	char* diff = 0
	char* text = mm_serialize_explain(d, &diff)
	if (text == 0):
		if (diff == 0): diff = strclone(c"serializer refused")
		return diff
	mm_document* again = mm_parse(text, strlen(text))
	char* second = mm_serialize(again)
	char* problem = 0
	if (second == 0): problem = strclone(c"canonical output does not serialize again")
	else if (strcmp(second, text) != 0): problem = strclone(c"serialization is not idempotent")
	if (second != 0): free(second)
	mm_document_free(again)
	free(text)
	return problem

int mm_rt_known_has(char* path):
	char* known = mm_rt_known()
	string_builder* needle = string_from(path)
	string_append_char(needle, 9)
	int at = index_of(known, needle.data)
	string_free(needle)
	return at == 0 || (at > 0 && known[at - 1] == 10)

void test_examples_round_trip():
	int report = mm_rt_reporting()
	int count = 0
	int failures = 0
	for char* path in glob_glob(c"examples/mermaid/*"):
		if (ends_with(path, c".mmd") == 0 && ends_with(path, c".md") == 0): continue
		int length = 0
		char* source = mm_read_source(path, &length)
		int diagrams = mm_source_diagram_count(source, length)
		free(source)
		for k in range(diagrams):
			mm_document* d = mm_read_selected(path, k)
			asserts(c"example parses", d != 0 && d.error == 0)
			char* problem = mm_rt_check(d)
			count = count + 1
			if (problem != 0):
				failures = failures + 1
				print2(path)
				print2(c": ")
				println2(problem)
				free(problem)
			mm_document_free(d)
	asserts(c"examples found", count >= 50)
	if (report == 0): assert_equal(0, failures)

void test_corpus_round_trip():
	int report = mm_rt_reporting()
	int length = 0
	char* manifest = mm_read_source(c"tests/mermaid_corpus/manifest.txt", &length)
	asserts(c"manifest readable", manifest != 0)
	char* text = str_copy_range(manifest, 0, length)
	free(manifest)
	int count = 0
	int unexpected = 0
	int stale = 0
	int known = 0
	for char* line in split(text, 10):
		if (line[0] == 0 || line[0] == '#'): continue
		list[char*] fields = split(line, 9)
		if (fields.length < 3 || starts_with(fields[2], c"error ")): continue
		char* path = mm_rt_join(c"tests/mermaid_corpus/", fields[0])
		mm_document* d = mm_read(path)
		char* problem = mm_rt_check(d)
		if (d != 0): mm_document_free(d)
		count = count + 1
		int listed = mm_rt_known_has(fields[0])
		if (listed): known = known + 1
		if (problem != 0 && listed == 0):
			unexpected = unexpected + 1
			print2(fields[0])
			print2(c": ")
			println2(problem)
		else if (problem == 0 && listed):
			stale = stale + 1
			print2(fields[0])
			println2(c": now round-trips; remove it from mm_rt_known")
		if (problem != 0): free(problem)
		free(path)
	print2(c"corpus round trips checked: ")
	println2(itoa(count))
	asserts(c"corpus examples found", count >= 500)
	if (report == 0):
		assert_equal(0, unexpected)
		assert_equal(0, stale)
	free(text)
