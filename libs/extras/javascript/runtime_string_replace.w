# Collect matches before callable replacements: callbacks observe final
# lastIndex and cannot change the match list. Named groups/@@replace/custom
# exec remain outside the supported RegExp profile, never approximated.
import libs.extras.javascript.runtime

void js_string_replace_callback(js_runtime* rt, js_value* callback, js_text* output, js_text* input, js_re_state* match):
	list[js_value*] args = new list[js_value*]
	for i in range(0, match.captures.length, 2):
		if (js_runtime_compat_step(rt) == 0): break
		args.push(js_re_slice(rt, input, match.captures[i], match.captures[i + 1]))
	if (rt.completion.status == 0):
		args.push(js_runtime_number(rt, cast(float64, match.captures[0])))
		args.push(js_runtime_string(rt, input))
	js_value* replaced = rt.undefined_value
	if (rt.completion.status == 0): replaced = js_runtime_call_receiver(rt, callback, rt.undefined_value, args)
	js_text* text = 0
	if (rt.completion.status == 0): text = js_runtime_string_text(rt, replaced)
	if (text != 0): js_re_append(rt, output, text, 0, text.units.length)
	js_text_free(text)
	__w_list_free(cast(__w_list*, args))

js_value* js_string_replace(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_builtin_arguments(rt, args) == 0): return rt.undefined_value
	if (receiver.kind == 0 || receiver.kind == 1):
		js_runtime_fail(rt, 2, c"replace requires a coercible receiver")
		return rt.undefined_value
	js_value* search = js_object_argument(rt, args, 0)
	js_value* replacement_value = js_object_argument(rt, args, 1)
	int callable = js_function_callable(replacement_value)
	js_text* input = js_runtime_string_text(rt, receiver)
	if (input == 0): return rt.undefined_value
	js_text* needle = 0
	if (search.regexp == 0): needle = js_runtime_string_text(rt, search)
	js_text* replacement = 0
	if (rt.completion.status == 0 && callable == 0): replacement = js_runtime_string_text(rt, replacement_value)
	list[js_re_state*] matches = new list[js_re_state*]
	if (search.regexp != 0 && rt.completion.status == 0):
		js_value* flags_value = js_runtime_get(rt, search, c"flags")
		js_text* flags = 0
		if (rt.completion.status == 0): flags = js_runtime_string_text(rt, flags_value)
		int global = 0
		int unicode = 0
		if (flags != 0):
			for i in range(flags.units.length):
				if (js_runtime_compat_step(rt) == 0): break
				if (flags.units[i] == 'g'): global = 1
				if (flags.units[i] == 'u' || flags.units[i] == 'v'): unicode = 1
		js_text_free(flags)
		if (global): js_re_last_index_set(rt, search, 0)
		while (rt.completion.status == 0):
			if (js_runtime_compat_step(rt) == 0 || js_re_check_exec(rt, search) == 0): break
			js_re_state* match = js_re_exec(rt, search, input)
			if (match == 0): break
			if (matches.length >= rt.max_properties):
				js_re_state_free(match)
				js_runtime_fail(rt, 5, c"RegExp replacement match limit")
				break
			matches.push(match)
			if (global == 0): break
			if (match.captures[0] == match.captures[1]):
				int index = js_re_last_index(rt, search, input.units.length)
				int advance = 1
				if (unicode && index >= 0 && index + 1 < input.units.length):
					int high = input.units[index]
					int low = input.units[index + 1]
					if (high >= 55296 && high <= 56319 && low >= 56320 && low <= 57343): advance = 2
				js_re_last_index_set(rt, search, index + advance)
	else if (needle != 0 && rt.completion.status == 0):
		for start in range(input.units.length - needle.units.length + 1):
			if (js_runtime_compat_step(rt) == 0): break
			int found = 1
			for i in range(needle.units.length):
				if (js_runtime_compat_step(rt) == 0 || input.units[start + i] != needle.units[i]):
					found = 0
					break
			if (found && rt.completion.status == 0):
				js_re_state* match = js_re_state_new(0, start + needle.units.length, 0, 2)
				match.captures[0] = start
				match.captures[1] = match.position
				matches.push(match)
				break
	js_text* output = js_text_new()
	int previous = 0
	for i in range(matches.length):
		if (rt.completion.status != 0): break
		js_re_state* match = matches[i]
		js_re_append(rt, output, input, previous, match.captures[0])
		if (rt.completion.status != 0): break
		if (callable): js_string_replace_callback(rt, replacement_value, output, input, match)
		else: js_re_substitute(rt, output, replacement, input, match)
		previous = match.captures[1]
	if (rt.completion.status == 0): js_re_append(rt, output, input, previous, input.units.length)
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_runtime_string(rt, output)
	for i in range(matches.length): js_re_state_free(matches[i])
	__w_list_free(cast(__w_list*, matches))
	js_text_free(input)
	js_text_free(needle)
	js_text_free(replacement)
	js_text_free(output)
	return result

void js_runtime_install_string_replace(js_runtime* rt):
	js_object_method(rt, rt.string_prototype, c"replace", js_string_replace, 0, 2)
