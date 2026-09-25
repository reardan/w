/*
Typed JSON field getters and the one build-manifest parser shared by
bin/wexec, bin/wtest, bin/wtest_map_check, bin/wbuildd and the
manifest generator (tools/wbuildgen_lib.w, which parses
build.base.json with it). tools/manifest_source.w decides where the
manifest text comes from; this module turns it into targets.
*/
import lib.lib
import structures.string
import structures.json


# object's key when it is a string, else 0 (absent or another type).
char* jfield_string(json_value* object, char* key):
	json_value* value = json_object_get(object, key)
	if ((value == 0) || (value.type != json_type_string())):
		return 0
	return value.string_value


# object's key when it is an array, else 0 (absent or another type).
json_value* jfield_array(json_value* object, char* key):
	json_value* value = json_object_get(object, key)
	if ((value == 0) || (value.type != json_type_array())):
		return 0
	return value


# object's key when it is an integer, else fallback.
int jfield_int(json_value* object, char* key, int fallback):
	json_value* value = json_object_get(object, key)
	if ((value == 0) || (value.type != json_type_int())):
		return fallback
	return value.int_value


# 1 when object's key is true or a nonzero integer, else 0.
int jfield_flag(json_value* object, char* key):
	json_value* value = json_object_get(object, key)
	if (value == 0):
		return 0
	if ((value.type == json_type_bool()) || (value.type == json_type_int())):
		return value.int_value != 0
	return 0


# A parsed manifest: the root object, its "targets" array, and the
# named targets in manifest order.
struct manifest:
	json_value* root
	json_value* targets
	list[char*] names
	map[char*, json_value*] by_name


char* manifest_parse_error   # why the last manifest_parse returned 0


void manifest_parse_fail(char* message, char* detail):
	string_builder* s = string_new()
	string_append(s, message)
	string_append(s, detail)
	manifest_parse_error = s.data
	free(s)


/* The manifest in root, an already parsed document (label names it in
errors: a path, or "build.base.json" for the generated manifest). The
root must be an object with a "targets" array. With strict set every
target must be an object with a "name" string and names must be unique
(what an executor or the generator needs); without it, entries that
are not named objects are skipped and a repeated name keeps its first
definition (what the selection tools need, which only look targets
up). Returns 0 after setting manifest_parse_error on failure. */
manifest* manifest_from_json(json_value* root, char* label, int strict):
	if (root.type != json_type_object()):
		manifest_parse_fail(c"manifest root must be a JSON object: ", label)
		return 0
	json_value* targets = json_object_get(root, c"targets")
	if (targets == 0):
		manifest_parse_fail(c"manifest has no \"targets\" array: ", label)
		return 0
	if (targets.type != json_type_array()):
		manifest_parse_fail(c"\"targets\" must be an array: ", label)
		return 0
	manifest* m = new manifest
	m.root = root
	m.targets = targets
	m.names = new list[char*]
	m.by_name = new map[char*, json_value*]
	int i = 0
	while (i < json_array_length(targets)):
		json_value* target = json_array_get(targets, i)
		i = i + 1
		char* name = 0
		if (target.type == json_type_object()):
			name = jfield_string(target, c"name")
		else if (strict):
			manifest_parse_fail(c"every target must be a JSON object: ", label)
			return 0
		if (name == 0):
			if (strict):
				manifest_parse_fail(c"target without a \"name\" string: ", label)
				return 0
			continue
		if (name in m.by_name):
			if (strict):
				manifest_parse_fail(c"duplicate target ", name)
				return 0
			continue
		m.by_name[name] = target
		m.names.push(name)
	return m


# manifest_from_json over manifest text (not freed); invalid JSON is a
# failure too.
manifest* manifest_parse(char* text, char* label, int strict):
	json_value* root = json_parse(text)
	if (root == 0):
		manifest_parse_fail(c"manifest is not valid JSON: ", label)
		return 0
	return manifest_from_json(root, label, strict)
