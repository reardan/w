# wbuild: arch_only=x64 deps=tests/orm/openapi/library.golden.json
# U4.2: the OpenAPI 3.0.3 document for the library fixture API
# (docs/projects/orm/u4_2.md). The rendered text must equal the golden
# tests/orm/openapi/library.golden.json byte for byte; the document is
# also checked structurally (required keys, every $ref resolves, unique
# operationIds, declared path parameters, required names exist) and, when
# python3 can import openapi_spec_validator (or at least jsonschema),
# validated by it. No database is needed.
#
# Regenerate the golden after an intended change with
#   ORM_OPENAPI_WRITE_GOLDEN=1 bin/orm_openapi_test
import tests.orm.fixtures.library_orm_api
import libs.standard.orm.rest.openapi
import lib.assert
import lib.file
import lib.process
import lib.shell


char* golden_path():
	return c"tests/orm/openapi/library.golden.json"


struct fixture_api:
	orm_api* api
	orm_serializer* tag
	orm_serializer* author
	orm_serializer* book
	orm_serializer* catalog
	orm_filter_set* book_filters
	orm_paginator* book_pages
	orm_paginator* author_pages
	orm_paginator* tag_pages


json_value* is_long_book(void* ctx, void* row):
	Book* b = cast(Book*, row)
	return json_bool(b.pages > 500)


# The fixture API, exercising every generator feature:
#   /books    full CRUD, nested tags, source and method fields, filters
#             (lookups, in, range, isnull, ordering, search), cursor
#             pagination, session + token auth, history route
#   /authors  full CRUD, a write-only field, a pk list, page numbers
#             with a client page size, session auth
#   /tags     read-only, limit/offset, token or anonymous
#   /catalog  read-only, a second Book serializer (named) with a nested
#             FK object, no pagination, no auth
fixture_api* build_api():
	fixture_api* f = new fixture_api()
	f.tag = orm_serializer_new(Tag_desc())

	f.author = orm_serializer_new(Author_desc())
	orm_serializer_write_only(f.author, c"email")
	orm_serializer_pk_list(f.author, c"books")

	f.book = orm_serializer_new(Book_desc())
	orm_serializer_source(f.book, c"author_name", c"author__name")
	orm_serializer_nested(f.book, c"tags", f.tag)
	orm_serializer_annotation(f.book, c"review_count", ORM_INT)
	orm_serializer_method(f.book, c"is_long", is_long_book, 0)

	f.catalog = orm_serializer_new(Book_desc())
	list[char*] keep = new list[char*]
	keep.push(c"id")
	keep.push(c"title")
	keep.push(c"author")
	keep.push(c"price")
	orm_serializer_include(f.catalog, keep)
	keep.free()
	orm_serializer_nested(f.catalog, c"author", f.author)

	f.book_filters = orm_filter_new(Book_desc())
	orm_filter_allow(f.book_filters, c"title", c"exact,icontains")
	orm_filter_allow(f.book_filters, c"price", c"gte,lte,range")
	orm_filter_allow(f.book_filters, c"status", c"exact,in")
	orm_filter_allow(f.book_filters, c"author", c"exact")
	orm_filter_allow(f.book_filters, c"tags__name", c"exact")
	orm_filter_allow(f.book_filters, c"pages", c"isnull")
	orm_filter_allow(f.book_filters, c"published_at", c"gte")
	orm_filter_ordering(f.book_filters, c"price")
	orm_filter_ordering(f.book_filters, c"title")
	orm_filter_search(f.book_filters, c"title")
	orm_filter_search(f.book_filters, c"author__name")
	f.book_pages = orm_paginator_cursor(c"title", 20)
	orm_paginator_client_size(f.book_pages, c"page_size", 50)
	orm_paginator_reserve(f.book_pages, f.book_filters)

	f.author_pages = orm_paginator_page_number(10)
	orm_paginator_client_size(f.author_pages, c"page_size", 100)
	f.tag_pages = orm_paginator_limit_offset(50)

	orm_api* api = orm_api_new(c"Library API", c"1.0.0")
	api.description = c"The w-orm library fixture (tests/orm/fixtures/library.orm)."
	orm_api_field_schema(api, f.book, c"is_long", json_parse(c"{\"type\": \"boolean\", \"readOnly\": true}"))
	orm_api_name(api, f.catalog, c"CatalogBook")

	orm_api_route* books = orm_api_add(api, c"/books", f.book)
	orm_api_route_filters(books, f.book_filters)
	orm_api_route_paginator(books, f.book_pages)
	orm_api_route_auth(books, ORM_API_AUTH_SESSION | ORM_API_AUTH_TOKEN)
	orm_api_route_history(books, 1)

	orm_api_route* authors = orm_api_add(api, c"/authors/", f.author)
	orm_api_route_paginator(authors, f.author_pages)
	orm_api_route_auth(authors, ORM_API_AUTH_SESSION)

	orm_api_route* tags = orm_api_add(api, c"/tags", f.tag)
	orm_api_route_actions(tags, ORM_API_READ_ONLY)
	orm_api_route_paginator(tags, f.tag_pages)
	orm_api_route_auth(tags, ORM_API_AUTH_TOKEN | ORM_API_AUTH_ANON)

	orm_api_route* catalog = orm_api_add(api, c"/catalog", f.catalog)
	orm_api_route_actions(catalog, ORM_API_READ_ONLY)
	orm_api_route_tag(catalog, c"books")
	f.api = api
	return f


# ---------------------------------------------------------------------------
# Structural checks

json_value* get(json_value* o, char* key):
	asserts(key, o != 0 && o.type == json_type_object())
	json_value* v = json_object_get(o, key)
	if (v == 0):
		print(c"missing key: ")
		println(key)
	asserts(key, v != 0)
	return v


char* get_string(json_value* o, char* key):
	json_value* v = get(o, key)
	asserts(key, v.type == json_type_string())
	return v.string_value


# "#/components/<section>/<name>" must name an existing entry.
void check_ref(json_value* doc, char* ref):
	asserts(ref, starts_with(ref, c"#/components/"))
	char* rest = ref + 13
	int slash = index_of(rest, c"/")
	asserts(ref, slash > 0)
	char* section = substring(rest, 0, slash)
	json_value* comp = get(doc, c"components")
	json_value* sec = json_object_get(comp, section)
	int ok = sec != 0 && json_object_has(sec, rest + slash + 1)
	if (ok == 0):
		print(c"unresolved $ref: ")
		println(ref)
	asserts(ref, ok)
	free(section)


# Every $ref in v resolves; returns how many were seen.
int check_refs(json_value* doc, json_value* v):
	int n = 0
	if (v.type == json_type_object()):
		for char* key, json_value* member in v.object_values:
			if (strcmp(key, c"$ref") == 0):
				asserts(c"$ref is a string", member.type == json_type_string())
				check_ref(doc, member.string_value)
				n = n + 1
			else: n = n + check_refs(doc, member)
	else if (v.type == json_type_array()):
		for json_value* item in v.array_values: n = n + check_refs(doc, item)
	return n


# Every schema "required" list is non-empty and names declared properties.
void check_required(json_value* v):
	if (v.type == json_type_array()):
		for json_value* item in v.array_values: check_required(item)
		return
	if (v.type != json_type_object()): return
	json_value* req = json_object_get(v, c"required")
	json_value* props = json_object_get(v, c"properties")
	if (req != 0 && req.type == json_type_array()):
		assert1(json_array_length(req) > 0)
		asserts(c"required without properties", props != 0)
		for json_value* name in req.array_values:
			asserts(name.string_value, json_object_has(props, name.string_value))
	for char* key, json_value* member in v.object_values: check_required(member)


int is_method(char* key):
	return strcmp(key, c"get") == 0 || strcmp(key, c"post") == 0 || strcmp(key, c"put") == 0 || strcmp(key, c"patch") == 0 || strcmp(key, c"delete") == 0


# {name} segments of a path template must be declared path parameters.
void check_path_params(char* path, json_value* item):
	json_value* params = json_object_get(item, c"parameters")
	int i = 0
	int n = strlen(path)
	while (i < n):
		if (path[i] == '{'):
			int end = i + 1
			while (end < n && path[end] != '}'): end = end + 1
			char* name = substring(path, i + 1, end)
			int found = 0
			if (params != 0):
				for json_value* p in params.array_values:
					if (strcmp(get_string(p, c"name"), name) == 0 && strcmp(get_string(p, c"in"), c"path") == 0):
						assert1(get(p, c"required").int_value == 1)
						found = 1
			asserts(name, found)
			free(name)
			i = end
		i = i + 1


# Returns the number of operations.
int check_operations(json_value* doc):
	list[char*] ids = new list[char*]
	json_value* paths = get(doc, c"paths")
	assert1(paths.object_values.length > 0)
	for char* path, json_value* item in paths.object_values:
		asserts(path, path[0] == '/')
		check_path_params(path, item)
		for char* method, json_value* op in item.object_values:
			if (is_method(method) == 0):
				asserts(method, strcmp(method, c"parameters") == 0)
				continue
			char* id = get_string(op, c"operationId")
			for char* seen in ids:
				if (strcmp(seen, id) == 0):
					print(c"duplicate operationId: ")
					println(id)
				asserts(id, strcmp(seen, id) != 0)
			ids.push(id)
			json_value* responses = get(op, c"responses")
			asserts(id, responses.object_values.length > 0)
			json_value* tags = get(op, c"tags")
			assert1(json_array_length(tags) == 1)
	int n = ids.length
	ids.free()
	return n


void check_structure(json_value* doc):
	assert_strings_equal(c"3.0.3", get_string(doc, c"openapi"))
	json_value* info = get(doc, c"info")
	assert_strings_equal(c"Library API", get_string(info, c"title"))
	assert_strings_equal(c"1.0.0", get_string(info, c"version"))
	json_value* comp = get(doc, c"components")
	get(comp, c"schemas")
	get(comp, c"responses")
	get(comp, c"securitySchemes")
	int refs = check_refs(doc, doc)
	assert1(refs > 40)
	check_required(doc)
	# 6 book + 1 history, 6 author, 2 tag, 2 catalog
	assert_equal(17, check_operations(doc))


# ---------------------------------------------------------------------------
# Spot checks of the generated shapes

json_value* schema(json_value* doc, char* name):
	return get(get(get(doc, c"components"), c"schemas"), name)


json_value* prop(json_value* doc, char* schema_name, char* field):
	return get(get(schema(doc, schema_name), c"properties"), field)


json_value* operation(json_value* doc, char* path, char* method):
	return get(get(get(doc, c"paths"), path), method)


int has_param(json_value* op, char* name):
	json_value* params = json_object_get(op, c"parameters")
	if (params == 0): return 0
	for json_value* p in params.array_values:
		if (strcmp(get_string(p, c"name"), name) == 0): return 1
	return 0


void expect_compact(char* want, json_value* got):
	char* text = json_stringify(got)
	if (strcmp(want, text) != 0):
		print(c"want: ")
		println(want)
		print(c"got:  ")
		println(text)
	assert_strings_equal(want, text)
	free(text)


void check_shapes(json_value* doc):
	# Read-only / write-only split.
	expect_compact(c"{\"type\":\"integer\",\"readOnly\":true}", prop(doc, c"Book", c"id"))
	assert1(json_object_has(get(schema(doc, c"BookRequest"), c"properties"), c"id") == 0)
	assert1(json_object_has(get(schema(doc, c"Author"), c"properties"), c"email") == 0)
	expect_compact(c"{\"type\":\"string\",\"maxLength\":254,\"minLength\":1,\"writeOnly\":true}", prop(doc, c"AuthorRequest", c"email"))
	expect_compact(c"[\"title\",\"author\",\"price\"]", get(schema(doc, c"BookRequest"), c"required"))
	assert1(json_object_has(schema(doc, c"PatchedBookRequest"), c"required") == 0)
	# Kinds.
	expect_compact(c"{\"type\":\"string\",\"format\":\"decimal\",\"pattern\":\"^-?\\\\d{0,6}(?:\\\\.\\\\d{0,2})?$\"}", prop(doc, c"Book", c"price"))
	expect_compact(c"{\"type\":\"integer\",\"nullable\":true}", prop(doc, c"Book", c"pages"))
	expect_compact(c"{\"type\":\"string\",\"format\":\"date-time\",\"nullable\":true}", prop(doc, c"Book", c"published_at"))
	expect_compact(c"{\"type\":\"string\",\"enum\":[\"draft\",\"pub\"]}", prop(doc, c"Book", c"status"))
	expect_compact(c"{\"type\":\"string\",\"maxLength\":300}", prop(doc, c"Book", c"title"))
	# Relations.
	expect_compact(c"{\"type\":\"integer\"}", prop(doc, c"Book", c"author"))
	expect_compact(c"{\"type\":\"array\",\"items\":{\"$ref\":\"#/components/schemas/Tag\"},\"readOnly\":true}", prop(doc, c"Book", c"tags"))
	expect_compact(c"{\"type\":\"array\",\"items\":{\"type\":\"integer\"},\"readOnly\":true}", prop(doc, c"Author", c"books"))
	expect_compact(c"{\"allOf\":[{\"$ref\":\"#/components/schemas/Author\"}],\"readOnly\":true}", prop(doc, c"CatalogBook", c"author"))
	expect_compact(c"{\"type\":\"string\",\"maxLength\":200,\"readOnly\":true}", prop(doc, c"Book", c"author_name"))
	expect_compact(c"{\"type\":\"boolean\",\"readOnly\":true}", prop(doc, c"Book", c"is_long"))
	# Envelopes.
	expect_compact(c"[\"next\",\"previous\",\"results\"]", get(schema(doc, c"CursorPaginatedBookList"), c"required"))
	expect_compact(c"[\"count\",\"next\",\"previous\",\"results\"]", get(schema(doc, c"PaginatedAuthorList"), c"required"))
	get(schema(doc, c"PaginatedTagList"), c"properties")
	get(schema(doc, c"HistoricalBook"), c"properties")
	# Parameters.
	json_value* list_books = operation(doc, c"/books", c"get")
	assert1(has_param(list_books, c"title__icontains"))
	assert1(has_param(list_books, c"price__range"))
	assert1(has_param(list_books, c"status__in"))
	assert1(has_param(list_books, c"pages__isnull"))
	assert1(has_param(list_books, c"ordering"))
	assert1(has_param(list_books, c"search"))
	assert1(has_param(list_books, c"cursor"))
	assert1(has_param(list_books, c"page_size"))
	assert1(has_param(list_books, c"title"))
	assert1(has_param(list_books, c"price") == 0)
	assert1(has_param(operation(doc, c"/authors/", c"get"), c"page"))
	assert1(has_param(operation(doc, c"/tags", c"get"), c"offset"))
	# Responses and security.
	json_value* create = operation(doc, c"/books", c"post")
	expect_compact(c"{\"$ref\":\"#/components/responses/ValidationError\"}", get(get(create, c"responses"), c"400"))
	expect_compact(c"[{\"cookieAuth\":[],\"csrfToken\":[]},{\"tokenAuth\":[]}]", get(create, c"security"))
	expect_compact(c"[{\"cookieAuth\":[]},{\"tokenAuth\":[]}]", get(list_books, c"security"))
	expect_compact(c"[{\"tokenAuth\":[]},{}]", get(operation(doc, c"/tags", c"get"), c"security"))
	assert1(json_object_has(operation(doc, c"/catalog", c"get"), c"security") == 0)
	assert1(json_object_has(get(operation(doc, c"/catalog", c"get"), c"responses"), c"401") == 0)
	json_value* destroy = operation(doc, c"/books/{id}", c"delete")
	assert1(json_object_has(get(destroy, c"responses"), c"204"))
	assert1(json_object_has(get(destroy, c"responses"), c"404"))
	operation(doc, c"/books/{id}/history", c"get")
	operation(doc, c"/authors/{id}/", c"patch")
	assert_strings_equal(c"X-CSRFToken", get_string(get(get(get(doc, c"components"), c"securitySchemes"), c"csrfToken"), c"name"))
	assert_strings_equal(c"cookie", get_string(get(get(get(doc, c"components"), c"securitySchemes"), c"cookieAuth"), c"in"))


# ---------------------------------------------------------------------------
# Configuration errors

void check_errors():
	orm_api* api = orm_api_new(c"Broken", c"0")
	orm_serializer* tag = orm_serializer_new(Tag_desc())
	orm_api_route_history(orm_api_add(api, c"/tags", tag), 1)
	json_value* doc = orm_openapi_document(api)
	asserts(c"history on a model without history", orm_api_error(api) != 0)
	assert_contains(orm_api_error(api), c"has no history")
	json_free(doc)
	orm_api_free(api)

	api = orm_api_new(c"Broken", c"0")
	orm_filter_set* fs = orm_filter_new(Tag_desc())
	orm_filter_allow(fs, c"nope", c"exact")
	orm_api_route_filters(orm_api_add(api, c"/tags", tag), fs)
	doc = orm_openapi_document(api)
	assert_contains(orm_api_error(api), c"not a field path")
	json_free(doc)
	orm_api_free(api)
	orm_filter_free(fs)

	# Duplicate route names get numbered operationIds.
	api = orm_api_new(c"Twice", c"0")
	orm_api_route_actions(orm_api_add(api, c"/tags", tag), ORM_API_LIST)
	orm_api_route_name(orm_api_route_actions(orm_api_add(api, c"/tags-again", tag), ORM_API_LIST), c"tags")
	doc = orm_openapi_document(api)
	asserts(c"no error", orm_api_error(api) == 0)
	assert_strings_equal(c"tags_list", get_string(operation(doc, c"/tags", c"get"), c"operationId"))
	assert_strings_equal(c"tags_list_2", get_string(operation(doc, c"/tags-again", c"get"), c"operationId"))
	json_free(doc)
	orm_api_free(api)
	orm_serializer_free(tag)


# ---------------------------------------------------------------------------
# Optional external validation

char* validator_script():
	return c"import json, sys\ndoc = json.load(sys.stdin)\ntry:\n    from openapi_spec_validator import validate\nexcept Exception:\n    validate = None\nif validate is not None:\n    validate(doc)\n    print('openapi-spec-validator: ok')\n    sys.exit(0)\ntry:\n    import jsonschema\nexcept Exception:\n    print('SKIP: no openapi_spec_validator or jsonschema')\n    sys.exit(0)\nfor name, s in doc['components']['schemas'].items():\n    jsonschema.Draft4Validator.check_schema(s)\nprint('jsonschema: %d component schemas ok' % len(doc['components']['schemas']))\n"


void check_with_python(char* text):
	char* python = process_which(c"python3")
	if (python == 0):
		println(c"orm_openapi_test: python validation SKIP (no python3)")
		return
	char** argv = strv_new(4)
	strv_set(argv, 0, python)
	strv_set(argv, 1, c"-I")
	strv_set(argv, 2, c"-c")
	strv_set(argv, 3, validator_script())
	process_result* res = process_run(python, argv, 0, text, 60000)
	asserts(c"python3 did not start", res != 0)
	if (res.status != 0):
		println(res.stdout_text)
		println(res.stderr_text)
	asserts(c"python validation failed", res.status == 0)
	print(c"orm_openapi_test: python ")
	print(res.stdout_text)
	process_result_free(res)


int main():
	library_register()
	fixture_api* f = build_api()
	char* text = orm_openapi_render(f.api)
	asserts(orm_api_error(f.api), orm_api_error(f.api) == 0)

	# Deterministic: a second rendering is identical.
	char* again = orm_openapi_render(f.api)
	assert_strings_equal(text, again)
	free(again)

	if (getenv(c"ORM_OPENAPI_WRITE_GOLDEN") != 0):
		assert1(file_write_text(golden_path(), text))
		println(c"orm_openapi_test: wrote the golden")
	char* golden = file_read_text(golden_path())
	asserts(c"golden file missing", golden != 0)
	if (strcmp(golden, text) != 0):
		file_write_text(c"bin/orm_openapi_test.actual.json", text)
		println(c"orm_openapi_test: output differs from the golden; see bin/orm_openapi_test.actual.json")
	assert_strings_equal(golden, text)
	free(golden)

	json_value* doc = json_parse(text)
	asserts(c"output parses as JSON", doc != 0)
	check_structure(doc)
	check_shapes(doc)
	json_free(doc)
	check_with_python(text)
	check_errors()
	free(text)
	println(c"orm_openapi_test: OK")
	return 0
