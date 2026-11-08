# wbuild: name=javascript_module_graph_test
# wbuild: target=javascript_module_graph_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 tests/javascript/module_graph_test.w -o bin/javascript_module_graph_test"
# wbuild: step="bin/javascript_module_graph_test"
# Static cross-module export resolution (sec-resolveexport).
import lib.testing
import libs.extras.javascript.module_graph


struct graph_fixture:
	list[char*] names
	list[char*] sources
	js_module_text text
	int loads


graph_fixture* graph_fixture_new():
	graph_fixture* fixture = new graph_fixture()
	fixture.names = new list[char*]
	fixture.sources = new list[char*]
	fixture.loads = 0
	return fixture


void graph_fixture_add(graph_fixture* fixture, char* name, char* source):
	fixture.names.push(name)
	fixture.sources.push(source)


js_module_text* graph_fixture_load(void* context, char* specifier, char* referrer):
	graph_fixture* fixture = cast(graph_fixture*, context)
	fixture.loads = fixture.loads + 1
	asserts(c"module graph", referrer != 0)
	for i in range(fixture.names.length):
		if (strcmp(fixture.names[i], specifier) == 0):
			fixture.text.identifier = fixture.names[i]
			fixture.text.source = fixture.sources[i]
			fixture.text.length = strlen(fixture.sources[i])
			return &fixture.text
	return 0


# Links root against the fixture and returns the error type ("" when linked).
char* graph_link(graph_fixture* fixture, char* root):
	js_module_graph* graph = js_module_graph_new(graph_fixture_load, fixture)
	int linked = js_module_graph_link(graph, c"root.mjs", root, strlen(root))
	char* type = c""
	if (linked == 0): type = graph.error_type
	asserts(c"module graph", (linked == 0) == (graph.error_type != 0))
	js_module_graph_free(graph)
	return type


void graph_expect(graph_fixture* fixture, char* root, char* type):
	char* actual = graph_link(fixture, root)
	if (strcmp(actual, type) != 0):
		println2(root)
		println2(actual)
	assert_equal(0, strcmp(actual, type))


graph_fixture* graph_star_fixture():
	graph_fixture* fixture = graph_fixture_new()
	graph_fixture_add(fixture, c"a", c"export const x = 1; export const onlyA = 2; export default 3;")
	graph_fixture_add(fixture, c"b", c"export const x = 4; export const onlyB = 5;")
	graph_fixture_add(fixture, c"star-a", c"export * from 'a';")
	graph_fixture_add(fixture, c"star-ab", c"export * from 'a'; export * from 'b';")
	graph_fixture_add(fixture, c"star-aa", c"export * from 'a'; export * from 'star-a';")
	graph_fixture_add(fixture, c"local-wins", c"export * from 'a'; export * from 'b'; export const x = 6;")
	graph_fixture_add(fixture, c"ns", c"export * as space from 'a';")
	graph_fixture_add(fixture, c"reexport-ns", c"import * as space from 'a'; export { space };")
	graph_fixture_add(fixture, c"renamed", c"import { onlyA as inner } from 'a'; export { inner as outer };")
	graph_fixture_add(fixture, c"cycle-1", c"export { x } from 'cycle-2';")
	graph_fixture_add(fixture, c"cycle-2", c"export { x } from 'cycle-1';")
	graph_fixture_add(fixture, c"self", c"export { x } from 'self';")
	graph_fixture_add(fixture, c"star-cycle-1", c"export * from 'star-cycle-2'; export const y = 1;")
	graph_fixture_add(fixture, c"star-cycle-2", c"export * from 'star-cycle-1';")
	graph_fixture_add(fixture, c"faulty", c"export { missing } from 'a';")
	graph_fixture_add(fixture, c"broken", c"export const = ;")
	graph_fixture_add(fixture, c"import-cycle-1", c"import { b } from 'import-cycle-2'; export const a = 1;")
	graph_fixture_add(fixture, c"import-cycle-2", c"import { a } from 'import-cycle-1'; export const b = 2;")
	return fixture


void test_module_graph_star_exports():
	graph_fixture* fixture = graph_star_fixture()
	graph_expect(fixture, c"import { x, onlyA } from 'star-a';", c"")
	graph_expect(fixture, c"import { onlyA, onlyB } from 'star-ab';", c"")
	graph_expect(fixture, c"import * as all from 'star-ab';", c"")
	graph_expect(fixture, c"export * from 'star-ab';", c"")
	graph_expect(fixture, c"import { missing } from 'star-a';", c"SyntaxError")


void test_module_graph_ambiguous_star_exports():
	graph_fixture* fixture = graph_star_fixture()
	graph_expect(fixture, c"import { x } from 'star-ab';", c"SyntaxError")
	graph_expect(fixture, c"export { x } from 'star-ab';", c"SyntaxError")
	# The same binding reached through two stars is not ambiguous.
	graph_expect(fixture, c"import { x } from 'star-aa';", c"")
	# Local and indirect exports shadow star exports.
	graph_expect(fixture, c"import { x } from 'local-wins';", c"")


void test_module_graph_default_never_star_exported():
	graph_fixture* fixture = graph_star_fixture()
	graph_expect(fixture, c"import x from 'a';", c"")
	graph_expect(fixture, c"import x from 'star-a';", c"SyntaxError")
	graph_expect(fixture, c"import { default as x } from 'star-a';", c"SyntaxError")
	graph_expect(fixture, c"export { default } from 'star-a';", c"SyntaxError")


void test_module_graph_namespace_and_renamed_exports():
	graph_fixture* fixture = graph_star_fixture()
	graph_expect(fixture, c"import { space } from 'ns';", c"")
	graph_expect(fixture, c"import { space } from 'reexport-ns';", c"")
	graph_expect(fixture, c"import { outer } from 'renamed';", c"")
	graph_expect(fixture, c"import { inner } from 'renamed';", c"SyntaxError")


void test_module_graph_cycles():
	graph_fixture* fixture = graph_star_fixture()
	graph_expect(fixture, c"import 'cycle-1';", c"SyntaxError")
	graph_expect(fixture, c"import 'self';", c"SyntaxError")
	graph_expect(fixture, c"import { y } from 'star-cycle-1';", c"")
	graph_expect(fixture, c"import { z } from 'star-cycle-1';", c"SyntaxError")
	graph_expect(fixture, c"import { a } from 'import-cycle-1';", c"")


void test_module_graph_load_failures():
	graph_fixture* fixture = graph_star_fixture()
	graph_expect(fixture, c"import 'faulty';", c"SyntaxError")
	graph_expect(fixture, c"import * as ns from 'faulty';", c"SyntaxError")
	graph_expect(fixture, c"import 'broken';", c"SyntaxError")
	graph_expect(fixture, c"import 'absent';", c"ReferenceError")
	graph_expect(fixture, c"export {} from 'absent';", c"ReferenceError")
	graph_expect(fixture, c"import {} from 'a'; import x from 'a';", c"")
	graph_expect(fixture, c"export const = ;", c"SyntaxError")


void test_module_graph_namespace_names():
	graph_fixture* fixture = graph_star_fixture()
	char* root = c"export * from 'star-ab'; export const own = 1;"
	js_module_graph* graph = js_module_graph_new(graph_fixture_load, fixture)
	assert_equal(1, js_module_graph_link(graph, c"root.mjs", root, strlen(root)))
	list[char*] names = js_module_namespace_names(graph, graph.records[0])
	# own, onlyA, onlyB: ambiguous x and star default are excluded.
	assert_equal(3, names.length)
	int ambiguous = 0
	for char* name in names:
		if (strcmp(name, c"x") == 0 || strcmp(name, c"default") == 0): ambiguous = 1
	assert_equal(0, ambiguous)
	__w_list_free(cast(__w_list*, names))
	js_module_graph_free(graph)


void test_module_graph_file_loader():
	js_module_file_loader* loader = js_module_file_loader_new(c"tests/javascript")
	asserts(c"module graph", js_module_file_load(loader, c"lib", c"tests/javascript/root.mjs") == 0)
	asserts(c"module graph", js_module_file_load(loader, c"../../build.base.json", c"tests/javascript/root.mjs") == 0)
	asserts(c"module graph", js_module_file_load(loader, c"./missing_FIXTURE.js", c"tests/javascript/root.mjs") == 0)
	js_module_text* text = js_module_file_load(loader, c"./module_graph_test.w", c"tests/javascript/root.mjs")
	asserts(c"module graph", text != 0)
	assert_equal(0, strcmp(text.identifier, c"tests/javascript/module_graph_test.w"))
	js_module_file_loader_free(loader)
