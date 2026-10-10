/* Native Mac planning. Keep the complete target registry and all explicit
compilation selectors, but run only the qualified native suite. The
transitive tests_darwin/generated closures define that qualification;
compile-only targets remain usable for cross compilation. Linux manifests
are unchanged. Apply after generation/validation, before planning/caching. */
import tools.build_host
import tools.manifest_json


void manifest_host_members(manifest* m, char* name, map[char*, int] seen):
	if (name in seen): return
	seen[name] = 1
	json_value* target = m.by_name.get(name, 0)
	if (target == 0): return
	json_value* deps = jfield_array(target, c"deps")
	if (deps == 0): return
	for i in range(json_array_length(deps)):
		json_value* dep = json_array_get(deps, i)
		if (dep.type == json_type_string()): manifest_host_members(m, dep.string_value, seen)


int manifest_host_selector(char* word):
	return strcmp(word, c"x64") == 0 || strcmp(word, c"arm64") == 0 || strcmp(word, c"arm64_darwin") == 0 || strcmp(word, c"win64") == 0 || strcmp(word, c"wasm") == 0


# Build-system tools and source generators must execute on the host.
# This does not change the default architecture of ordinary tests.
void manifest_host_commands(json_value* target, int native):
	json_value* steps = jfield_array(target, c"steps")
	if (steps == 0): return
	for i in range(json_array_length(steps)):
		json_value* step = json_array_get(steps, i)
		json_value* cmd = jfield_array(step, c"cmd")
		if (cmd == 0 || json_array_length(cmd) == 0): continue
		json_value* first = json_array_get(cmd, 0)
		if (first.type != json_type_string()): continue
		if (strcmp(first.string_value, c"bin/wv2") != 0): continue
		json_value* out = json_array()
		json_array_push(out, json_string(c"bin/wv2_darwin"))
		int explicit_arch = 0
		if (json_array_length(cmd) > 1):
			json_value* second = json_array_get(cmd, 1)
			if (second.type == json_type_string()): explicit_arch = manifest_host_selector(second.string_value)
		if (native && explicit_arch == 0): json_array_push(out, json_string(c"arm64_darwin"))
		for j in range(1, json_array_length(cmd)): json_array_push(out, json_clone(json_array_get(cmd, j)))
		json_object_set(step, c"cmd", out)
		# Use fresh inodes for native outputs (macOS signature caching).
		for j in range(1, json_array_length(out) - 1):
			json_value* arg = json_array_get(out, j)
			if (arg.type == json_type_string() && strcmp(arg.string_value, c"-o") == 0 && json_object_get(step, c"atomic_output") == 0):
				json_object_set(step, c"atomic_output", json_clone(json_array_get(out, j + 1)))


int manifest_host_compile_only(json_value* target):
	json_value* steps = jfield_array(target, c"steps")
	if (steps == 0 || json_array_length(steps) == 0): return 0
	for i in range(json_array_length(steps)):
		json_value* cmd = jfield_array(json_array_get(steps, i), c"cmd")
		if (cmd == 0 || json_array_length(cmd) == 0): return 0
		json_value* first = json_array_get(cmd, 0)
		if (first.type != json_type_string()): return 0
		char* program = first.string_value
		if (strcmp(program, c"bin/wv2_darwin") != 0 && strcmp(program, c"cp") != 0 && strcmp(program, c"mv") != 0): return 0
	return 1


# A bootstrapped host executable is an input, so downstream cache keys
# change when it does. The shell refreshes these before entering wexec.
void manifest_host_bootstrap(manifest* m, char* name, char* binary):
	json_value* target = m.by_name.get(name, 0)
	if (target == 0): return
	json_object_set(target, c"steps", json_array())
	json_object_set(target, c"deps", json_array())
	json_value* inputs = json_array()
	json_array_push(inputs, json_string(binary))
	json_object_set(target, c"inputs", inputs)
	json_value* outputs = json_array()
	json_array_push(outputs, json_string(binary))
	json_object_set(target, c"outputs", outputs)


# Unavailability propagates through tool dependencies too; --available
# must never recommend a cross compile whose prerequisite cannot run.
char* manifest_host_unavailable(manifest* m, char* name, map[char*, int] seen):
	if (name in seen): return 0
	seen[name] = 1
	json_value* target = m.by_name.get(name, 0)
	if (target == 0): return 0
	char* reason = jfield_string(target, c"host_unavailable")
	if (reason != 0): return reason
	json_value* deps = jfield_array(target, c"deps")
	if (deps == 0): return 0
	for i in range(json_array_length(deps)):
		json_value* dep = json_array_get(deps, i)
		if (dep.type != json_type_string()): continue
		reason = manifest_host_unavailable(m, dep.string_value, seen)
		if (reason != 0): return reason
	return 0


void manifest_host_prepare_darwin(manifest* m, int repository):
	map[char*, int] native = new map[char*, int]
	map[char*, int] generators = new map[char*, int]
	map[char*, int] original = new map[char*, int]
	map[char*, int] suite = new map[char*, int]
	if (repository):
		manifest_host_members(m, c"tests", original)
		manifest_host_members(m, c"tests_darwin", native)
		manifest_host_members(m, c"tests_darwin", suite)
		manifest_host_members(m, c"generated", suite)
		manifest_host_members(m, c"generated", generators)
		for char* name, int member in generators: native[name] = member
		manifest_host_members(m, c"wtest", native)
		manifest_host_members(m, c"manifest_check", native)
		manifest_host_members(m, c"metadata_check", native)
		manifest_host_bootstrap(m, c"wv2", c"bin/wv2_darwin")
		manifest_host_bootstrap(m, c"wexec", c"bin/wexec_darwin")
		native[c"wexec"] = 1
		native[c"wexec_darwin"] = 1
		native[c"update_darwin"] = 1
		native[c"manifest"] = 1
		native[c"wtest_cache"] = 1
	for char* name in m.names:
		json_value* target = m.by_name[name]
		int host_tool = name in generators || strcmp(name, c"wtest") == 0 || strcmp(name, c"wbuildgen") == 0 || strcmp(name, c"wmeta") == 0
		manifest_host_commands(target, repository && host_tool)
		if (repository && (name in native) == 0 && strcmp(name, c"tests") != 0):
			if (manifest_host_compile_only(target) == 0):
				json_object_set(target, c"host_unavailable", json_string(c"outside the qualified native macOS suite (requires another platform/runtime or a native port)"))
	if (repository):
		json_value* tests = m.by_name.get(c"tests", 0)
		if (tests != 0):
			int skipped = 0
			for char* name, int member in original:
				json_value* target = m.by_name.get(name, 0)
				if (target == 0 || name in suite): continue
				json_value* steps = jfield_array(target, c"steps")
				if (steps != 0 && json_array_length(steps) > 0): skipped = skipped + member
			json_value* deps = json_array()
			json_array_push(deps, json_string(c"tests_darwin"))
			json_object_set(tests, c"deps", deps)
			json_object_set(tests, c"host_skipped", json_int(skipped))

		for char* name in m.names:
			char* reason = manifest_host_unavailable(m, name, new map[char*, int])
			if (reason != 0): json_object_set(m.by_name[name], c"host_unavailable", json_string(reason))


void manifest_host_prepare(manifest* m, int repository):
	if (build_host_darwin()): manifest_host_prepare_darwin(m, repository)
