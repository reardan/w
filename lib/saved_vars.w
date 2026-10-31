# SavedVariables for addons (docs/projects/scripting.md S2): state that
# survives a reload, and optionally the process, as JSON.
#
# The engine's reload resets an addon's state: functions repatch, data
# does not migrate (scripting.md S1). An addon keeps what must survive in
# a struct that to_json/from_json can encode (structures/json_codec.w),
# and the host stores it before the rollback and restores it after the
# reload:
#
#   void saved_vars_store(char* key, char* json_text)
#       Keep a copy of json_text (an addon's to_json value, stringified)
#       under key, replacing an earlier one. key is usually the addon's
#       name, or "addon.global" for several values per addon.
#   char* saved_vars_restore(char* key, char* defaults_json)
#       The stored value reshaped to the layout of defaults_json (the
#       freshly loaded addon's to_json value), as JSON text for from_json:
#       members are matched by name, so a field the new layout added keeps
#       its default, a field it removed is dropped, and a member whose JSON
#       type changed keeps the default too (int and float convert). Arrays
#       and strings are taken whole. With nothing stored, or text that
#       does not parse, the defaults come back unchanged. The result is
#       owned by this module and stays valid until the next restore of the
#       same key.
#   int saved_vars_write_file(char* path) / int saved_vars_read_file(char* path)
#       Persist every stored key as one JSON object ({key: value, ...}),
#       or load such a file (replacing the stored keys it names). 1 on
#       success.
#
# The store lives in the host's heap, never in the engine session, so a
# rollback cannot take it with it; repl/embed.w's engine_saved_vars does
# the store/restore around engine_reload automatically for registered
# globals. Only JSON text crosses between the host and the session heaps.
import lib.file
import structures.json


map[char*, char*] saved_vars_values
map[char*, char*] saved_vars_restored


void saved_vars_init():
	if (saved_vars_values == 0):
		saved_vars_values = new map[char*, char*]
		saved_vars_restored = new map[char*, char*]


void saved_vars_put(map[char*, char*] m, char* key, char* text):
	if (key in m):
		free(m[key])
		m[key] = text
		return;
	m[key] = text


void saved_vars_store(char* key, char* json_text):
	saved_vars_init()
	if ((key == 0) || (json_text == 0)): return;
	saved_vars_put(saved_vars_values, key, strclone(json_text))


int saved_vars_has(char* key):
	saved_vars_init()
	return key in saved_vars_values


# The stored JSON text for key, or 0. Owned by the store.
char* saved_vars_get(char* key):
	saved_vars_init()
	return saved_vars_values.get(key, 0)


void saved_vars_forget(char* key):
	saved_vars_init()
	if (key in saved_vars_values):
		free(saved_vars_values[key])
		saved_vars_values.remove(key)


int saved_vars_is_number(json_value* v):
	return (v.type == json_type_int()) || (v.type == json_type_float())


# A new value with the layout of defaults filled from stored (see
# saved_vars_restore); neither argument is modified.
json_value* saved_vars_merge(json_value* defaults, json_value* stored):
	if (defaults == 0): return 0
	if (stored == 0): return json_clone(defaults)
	if ((defaults.type == json_type_object()) && (stored.type == json_type_object())):
		json_value* merged = json_object()
		for char* key, json_value* member in defaults.object_values:
			json_object_set(merged, key, saved_vars_merge(member, json_object_get(stored, key)))
		return merged
	if (defaults.type == stored.type): return json_clone(stored)
	if (saved_vars_is_number(defaults) && saved_vars_is_number(stored)):
		json_value* number = json_clone(defaults)
		if (defaults.type == json_type_int()): number.int_value = stored.float_value
		else:
			number.float_value = stored.int_value
			number.has_float64 = 0
		return number
	# A null default (a char*, list or map field that was 0) takes any
	# stored value of a reference type; a stored null clears the field.
	if ((defaults.type == json_type_null()) && (saved_vars_is_number(stored) == 0) && (stored.type != json_type_bool())): return json_clone(stored)
	if ((stored.type == json_type_null()) && (saved_vars_is_number(defaults) == 0) && (defaults.type != json_type_bool())): return json_null()
	return json_clone(defaults)


char* saved_vars_restore(char* key, char* defaults_json):
	saved_vars_init()
	if ((key == 0) || (defaults_json == 0)): return defaults_json
	char* result = 0
	json_value* defaults = json_parse(defaults_json)
	char* text = saved_vars_values.get(key, 0)
	json_value* stored = 0
	if (text != 0): stored = json_parse(text)
	if ((defaults != 0) && (stored != 0)):
		json_value* merged = saved_vars_merge(defaults, stored)
		result = json_stringify(merged)
		json_free(merged)
	else: result = strclone(defaults_json)
	if (defaults != 0): json_free(defaults)
	if (stored != 0): json_free(stored)
	saved_vars_put(saved_vars_restored, key, result)
	return result


int saved_vars_write_file(char* path):
	saved_vars_init()
	json_value* all = json_object()
	for char* key, char* text in saved_vars_values:
		json_value* v = json_parse(text)
		if (v == 0): v = json_null()
		json_object_set(all, key, v)
	char* out = json_stringify(all)
	json_free(all)
	int ok = file_write_text(path, out)
	free(out)
	return ok


int saved_vars_read_file(char* path):
	saved_vars_init()
	char* text = file_read_text(path)
	if (text == 0): return 0
	json_value* all = json_parse(text)
	free(text)
	if (all == 0): return 0
	if (all.type != json_type_object()):
		json_free(all)
		return 0
	for char* key, json_value* member in all.object_values: saved_vars_put(saved_vars_values, key, json_stringify(member))
	json_free(all)
	return 1
