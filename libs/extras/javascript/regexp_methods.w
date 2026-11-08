# String.prototype match/matchAll/replace/search/split and the RegExp
# Symbol.match/matchAll/replace/search/split methods (ECMA-262 2020
# sec-string.prototype.match ... sec-regexp.prototype-@@split), plus
# RegExpExec, RegExp[Symbol.species], %RegExpStringIteratorPrototype% and
# String.prototype.toString/valueOf.
#
# The String methods dispatch through the argument's Symbol.* method when it
# has one, exactly as specified, so user objects can replace the RegExp
# behaviour. Every exec, loop iteration and copied or substituted code unit
# is charged to the evaluation step budget. ES2020 is followed where later
# editions differ: matchAll does not reject a non-global RegExp.
import libs.extras.javascript.runtime


const int JS_BRAND_STRING = 1
const int JS_BRAND_REGEXP_ITERATOR = 2
const int JS_RX_ITER_GLOBAL = 4
const int JS_RX_ITER_UNICODE = 8
const int JS_RX_ITER_DONE = 16


# Charge count steps at once (copied units, substitutions).
int js_rx_charge(js_runtime* rt, int count):
	if (rt.completion.status != 0): return 0
	if (count <= 0): return 1
	if (rt.remaining < count):
		rt.remaining = 0
		js_runtime_fail(rt, 5, c"JavaScript iteration limit")
		return 0
	rt.remaining = rt.remaining - count
	rt.completion.steps = rt.completion.steps + count
	return 1


js_value* js_rx_null(js_runtime* rt):
	return js_runtime_alloc(rt, 1)


js_value* js_rx_argument(js_runtime* rt, list[js_value*] args, int index):
	if (index < args.length): return args[index]
	return rt.undefined_value


# Append units[start:end] to out, charging each unit and the string limit.
int js_rx_append(js_runtime* rt, js_text* out, list[int] units, int start, int end):
	if (end <= start): return 1
	if (out.units.length + end - start > rt.max_properties):
		js_runtime_fail(rt, 5, c"JavaScript string length limit")
		return 0
	if (js_rx_charge(rt, end - start) == 0): return 0
	for i in range(start, end): out.units.push(units[i])
	return 1


js_value* js_rx_substring(js_runtime* rt, list[int] units, int start, int end):
	if (js_rx_charge(rt, end - start) == 0): return rt.undefined_value
	return js_regexp_text_value(rt, units, start, end)


int js_rx_flag(js_runtime* rt, js_value* object, char* name):
	js_value* value = js_runtime_get(rt, object, name)
	if (rt.completion.status != 0): return 0
	return js_runtime_truth(value)


# Set(O, name, value, true).
void js_rx_put(js_runtime* rt, js_value* object, char* name, js_value* value):
	if (rt.completion.status != 0): return
	js_text* key = js_runtime_key(name)
	int written = js_runtime_member_write(rt, object, key, value)
	js_text_free(key)
	if (written == 0): js_runtime_fail(rt, 2, c"property write rejected")


void js_rx_put_index(js_runtime* rt, js_value* object, int index):
	js_rx_put(rt, object, c"lastIndex", js_runtime_number(rt, cast(float64, index)))


int js_rx_get_length(js_runtime* rt, js_value* object, char* name):
	js_value* value = js_runtime_get(rt, object, name)
	if (rt.completion.status != 0): return 0
	return js_runtime_to_length(rt, value)


# AdvanceStringIndex.
int js_rx_advance(list[int] units, int index, int unicode):
	if (unicode == 0 || index + 1 >= units.length): return index + 1
	if (js_regexp_lead(units[index]) && js_regexp_trail(units[index + 1])): return index + 2
	return index + 1


# RegExpExec (sec-regexpexec): a callable exec property wins; otherwise the
# receiver must be a RegExp. Returns an object or null.
js_value* js_regexp_exec_generic(js_runtime* rt, js_value* object, js_value* subject):
	if (js_rx_charge(rt, 1) == 0): return rt.undefined_value
	js_value* exec = js_runtime_get(rt, object, c"exec")
	if (rt.completion.status != 0): return rt.undefined_value
	if (js_runtime_callable(exec)):
		js_value* result = js_runtime_call1(rt, exec, object, subject)
		if (rt.completion.status != 0): return rt.undefined_value
		if (js_runtime_object(result) == 0 && result.kind != 1): return js_runtime_type_error(rt, c"RegExp exec result is not an object or null")
		return result
	if (object.regexp == 0): return js_runtime_type_error(rt, c"RegExp method requires a RegExp receiver")
	return js_regexp_exec(rt, object, subject.text)


# ToString(Get(result, "0")) for a match result.
js_text* js_rx_match_text(js_runtime* rt, js_value* result):
	js_value* matched = js_runtime_get(rt, result, c"0")
	if (rt.completion.status != 0): return 0
	return js_runtime_to_text(rt, matched)


# An empty global match advances lastIndex so the loop terminates.
void js_rx_advance_empty(js_runtime* rt, js_value* rx, js_value* subject, int unicode):
	int index = js_regexp_last_index(rt, rx)
	if (rt.completion.status != 0): return
	js_rx_put_index(rt, rx, js_rx_advance(subject.text.units, index, unicode))


# SpeciesConstructor(O, %RegExp%).
js_value* js_rx_species(js_runtime* rt, js_value* object):
	js_value* constructor = js_runtime_get(rt, object, c"constructor")
	if (rt.completion.status != 0): return 0
	if (constructor.kind == 0): return rt.regexp_constructor
	if (js_runtime_object(constructor) == 0):
		js_runtime_fail(rt, 2, c"constructor is not an object")
		return 0
	js_text* key = js_symbol_key(JS_SYMBOL_SPECIES)
	js_value* species = js_runtime_member_read(rt, constructor, key)
	js_text_free(key)
	if (rt.completion.status != 0): return 0
	if (species.kind == 0 || species.kind == 1): return rt.regexp_constructor
	if (js_runtime_is_constructor(rt, species)): return species
	js_runtime_fail(rt, 2, c"Symbol.species is not a constructor")
	return 0


# Construct(C, « rx, flags »); the result must be an object.
js_value* js_rx_construct(js_runtime* rt, js_value* constructor, js_value* rx, js_value* flags):
	list[js_value*] args = new list[js_value*]
	args.push(rx)
	args.push(flags)
	js_value* result = js_runtime_construct(rt, constructor, args, constructor)
	__w_list_free(cast(__w_list*, args))
	if (rt.completion.status != 0): return 0
	if (js_runtime_object(result) == 0):
		js_runtime_fail(rt, 2, c"species constructor returned a non-object")
		return 0
	return result


int js_rx_has_unit(js_text* text, int unit):
	for int item in text.units:
		if (item == unit): return 1
	return 0


# GetSubstitution (sec-getsubstitution). captures holds undefined or string
# values; named is undefined or an object. Returns owned text or 0.
js_text* js_rx_substitution(js_runtime* rt, js_text* matched, js_text* str, int position, list[js_value*] captures, js_value* named, js_text* replacement):
	js_text* out = js_text_new()
	list[int] template = replacement.units
	int length = template.length
	int m = captures.length
	int tail = position + matched.units.length
	int i = 0
	while (i < length && rt.completion.status == 0):
		if (js_rx_charge(rt, 1) == 0): break
		int ch = template[i]
		if (ch != '$' || i + 1 >= length):
			js_rx_append(rt, out, template, i, i + 1)
			i = i + 1
			continue
		int next = template[i + 1]
		if (next == '$'):
			out.units.push('$')
			i = i + 2
		else if (next == '&'):
			js_rx_append(rt, out, matched.units, 0, matched.units.length)
			i = i + 2
		else if (next == '`'):
			js_rx_append(rt, out, str.units, 0, position)
			i = i + 2
		else if (next == 39):
			if (tail < str.units.length): js_rx_append(rt, out, str.units, tail, str.units.length)
			i = i + 2
		else if (next >= '0' && next <= '9'):
			# Two digits win when they name a capture ($10 with ten groups);
			# otherwise one digit; otherwise the text stays literal.
			int index = next - '0'
			int width = 2
			if (i + 2 < length && template[i + 2] >= '0' && template[i + 2] <= '9'):
				int two = index * 10 + template[i + 2] - '0'
				if (two >= 1 && two <= m):
					index = two
					width = 3
			if (index >= 1 && index <= m):
				js_value* capture = captures[index - 1]
				if (capture.kind == 4): js_rx_append(rt, out, capture.text.units, 0, capture.text.units.length)
				i = i + width
			else:
				js_rx_append(rt, out, template, i, i + 2)
				i = i + 2
		else if (next == '<'):
			int close = -1
			if (named.kind != 0):
				for j in range(i + 2, length):
					if (template[j] == '>'):
						close = j
						break
			if (close < 0):
				js_rx_append(rt, out, template, i, i + 2)
				i = i + 2
			else:
				js_text* name = js_text_new()
				for j in range(i + 2, close): name.units.push(template[j])
				js_value* capture = js_runtime_member_read(rt, named, name)
				js_text_free(name)
				if (rt.completion.status == 0 && capture.kind != 0):
					js_text* text = js_runtime_to_text(rt, capture)
					if (text != 0):
						js_rx_append(rt, out, text.units, 0, text.units.length)
						js_text_free(text)
				i = close + 1
		else:
			out.units.push('$')
			i = i + 1
	if (rt.completion.status != 0):
		js_text_free(out)
		return 0
	return out


# RegExp.prototype[Symbol.match].
js_value* js_rx_symbol_match(js_runtime* rt, js_value* rx, js_value* subject):
	if (js_rx_flag(rt, rx, c"global") == 0):
		if (rt.completion.status != 0): return rt.undefined_value
		return js_regexp_exec_generic(rt, rx, subject)
	int unicode = js_rx_flag(rt, rx, c"unicode")
	js_rx_put_index(rt, rx, 0)
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* array = js_runtime_alloc(rt, 6)
	int n = 0
	while (js_runtime_compat_step(rt)):
		js_value* result = js_regexp_exec_generic(rt, rx, subject)
		if (rt.completion.status != 0): break
		if (result.kind == 1):
			if (n == 0): return result
			return array
		js_text* matched = js_rx_match_text(rt, result)
		if (matched == 0): break
		js_value* item = js_runtime_string(rt, matched)
		int empty = matched.units.length == 0
		js_text_free(matched)
		js_runtime_array_append(rt, array, item)
		if (empty): js_rx_advance_empty(rt, rx, subject, unicode)
		n = n + 1
	return rt.undefined_value


# RegExp.prototype[Symbol.replace].
js_value* js_rx_symbol_replace(js_runtime* rt, js_value* rx, js_value* subject, js_value* replace_value):
	js_text* template = 0
	int functional = js_runtime_callable(replace_value)
	if (functional == 0):
		template = js_runtime_to_text(rt, replace_value)
		if (template == 0): return rt.undefined_value
	int global = js_rx_flag(rt, rx, c"global")
	int unicode = 0
	if (global && rt.completion.status == 0):
		unicode = js_rx_flag(rt, rx, c"unicode")
		js_rx_put_index(rt, rx, 0)
	list[js_value*] results = new list[js_value*]
	while (rt.completion.status == 0 && js_runtime_compat_step(rt)):
		js_value* result = js_regexp_exec_generic(rt, rx, subject)
		if (rt.completion.status != 0 || result.kind == 1): break
		results.push(result)
		if (global == 0): break
		js_text* matched = js_rx_match_text(rt, result)
		if (matched == 0): break
		if (matched.units.length == 0): js_rx_advance_empty(rt, rx, subject, unicode)
		js_text_free(matched)
	list[int] units = subject.text.units
	js_text* out = js_text_new()
	int next_position = 0
	for js_value* result in results:
		if (rt.completion.status != 0 || js_runtime_compat_step(rt) == 0): break
		int count = js_rx_get_length(rt, result, c"length") - 1
		if (count < 0): count = 0
		js_text* matched = js_rx_match_text(rt, result)
		if (matched == 0): break
		js_value* index = js_runtime_get(rt, result, c"index")
		int position = 0
		if (rt.completion.status == 0): position = js_runtime_clamp(js_runtime_to_integer(rt, index), units.length)
		list[js_value*] captures = new list[js_value*]
		for n in range(1, count + 1):
			if (js_runtime_compat_step(rt) == 0): break
			char* name = itoa(n)
			js_value* capture = js_runtime_get(rt, result, name)
			free(name)
			if (rt.completion.status == 0 && capture.kind != 0): capture = js_runtime_to_string_value(rt, capture)
			captures.push(capture)
		js_value* named = rt.undefined_value
		if (rt.completion.status == 0): named = js_runtime_get(rt, result, c"groups")
		js_text* replacement = 0
		if (rt.completion.status == 0):
			if (functional):
				list[js_value*] arguments = new list[js_value*]
				arguments.push(js_runtime_string(rt, matched))
				for js_value* capture in captures: arguments.push(capture)
				arguments.push(js_runtime_number(rt, cast(float64, position)))
				arguments.push(subject)
				if (named.kind != 0): arguments.push(named)
				js_value* value = js_runtime_call_receiver(rt, replace_value, rt.undefined_value, arguments)
				__w_list_free(cast(__w_list*, arguments))
				if (rt.completion.status == 0): replacement = js_runtime_to_text(rt, value)
			else:
				# ToObject(groups): null throws; property reads of other
				# primitives already behave like reads of their wrappers.
				if (named.kind == 1): js_runtime_fail(rt, 2, c"RegExp groups is not an object")
				if (rt.completion.status == 0): replacement = js_rx_substitution(rt, matched, subject.text, position, captures, named, template)
		__w_list_free(cast(__w_list*, captures))
		if (replacement != 0 && position >= next_position):
			js_rx_append(rt, out, units, next_position, position)
			js_rx_append(rt, out, replacement.units, 0, replacement.units.length)
			next_position = position + matched.units.length
		js_text_free(replacement)
		js_text_free(matched)
	__w_list_free(cast(__w_list*, results))
	js_text_free(template)
	if (next_position < units.length): js_rx_append(rt, out, units, next_position, units.length)
	js_value* value = rt.undefined_value
	if (rt.completion.status == 0): value = js_runtime_string(rt, out)
	js_text_free(out)
	return value


# RegExp.prototype[Symbol.search]: lastIndex is restored afterwards.
js_value* js_rx_symbol_search(js_runtime* rt, js_value* rx, js_value* subject):
	js_value* previous = js_runtime_get(rt, rx, c"lastIndex")
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* zero = js_runtime_number(rt, 0.0)
	if (js_runtime_same_value(previous, zero) == 0): js_rx_put(rt, rx, c"lastIndex", zero)
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* result = js_regexp_exec_generic(rt, rx, subject)
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* current = js_runtime_get(rt, rx, c"lastIndex")
	if (rt.completion.status != 0): return rt.undefined_value
	if (js_runtime_same_value(current, previous) == 0): js_rx_put(rt, rx, c"lastIndex", previous)
	if (rt.completion.status != 0): return rt.undefined_value
	if (result.kind == 1): return js_runtime_number(rt, -1.0)
	return js_runtime_get(rt, result, c"index")


# RegExp.prototype[Symbol.split]: a sticky copy from the species
# constructor is matched at each position.
js_value* js_rx_symbol_split(js_runtime* rt, js_value* rx, js_value* subject, js_value* limit):
	js_value* constructor = js_rx_species(rt, rx)
	if (constructor == 0): return rt.undefined_value
	js_text* flags = js_runtime_to_text(rt, js_runtime_get(rt, rx, c"flags"))
	if (flags == 0): return rt.undefined_value
	int unicode = js_rx_has_unit(flags, 'u')
	if (js_rx_has_unit(flags, 'y') == 0): flags.units.push('y')
	js_value* flag_value = js_runtime_string(rt, flags)
	js_text_free(flags)
	js_value* splitter = js_rx_construct(rt, constructor, rx, flag_value)
	if (splitter == 0): return rt.undefined_value
	js_value* array = js_runtime_alloc(rt, 6)
	int lim = (1 << 32) - 1
	if (limit.kind != 0): lim = js_runtime_to_uint32(rt, limit)
	if (rt.completion.status != 0 || lim == 0): return array
	list[int] units = subject.text.units
	int size = units.length
	if (size == 0):
		js_value* z = js_regexp_exec_generic(rt, splitter, subject)
		if (rt.completion.status == 0 && z.kind == 1): js_runtime_array_append(rt, array, subject)
		return array
	int p = 0
	int q = 0
	while (q < size && js_runtime_compat_step(rt)):
		js_rx_put_index(rt, splitter, q)
		js_value* z = js_regexp_exec_generic(rt, splitter, subject)
		if (rt.completion.status != 0): return array
		if (z.kind == 1):
			q = js_rx_advance(units, q, unicode)
			continue
		int e = js_regexp_last_index(rt, splitter)
		if (rt.completion.status != 0): return array
		if (e > size): e = size
		if (e == p):
			q = js_rx_advance(units, q, unicode)
			continue
		js_runtime_array_append(rt, array, js_rx_substring(rt, units, p, q))
		if (array.array_length == lim || rt.completion.status != 0): return array
		p = e
		int count = js_rx_get_length(rt, z, c"length") - 1
		if (count < 0): count = 0
		for i in range(1, count + 1):
			if (js_runtime_compat_step(rt) == 0): return array
			char* name = itoa(i)
			js_value* capture = js_runtime_get(rt, z, name)
			free(name)
			js_runtime_array_append(rt, array, capture)
			if (array.array_length == lim || rt.completion.status != 0): return array
		q = p
	if (rt.completion.status == 0): js_runtime_array_append(rt, array, js_rx_substring(rt, units, p, size))
	return array


# RegExp.prototype[Symbol.matchAll]: a species copy with the same flags and
# lastIndex drives a RegExp String Iterator.
js_value* js_rx_symbol_match_all(js_runtime* rt, js_value* rx, js_value* subject):
	js_value* constructor = js_rx_species(rt, rx)
	if (constructor == 0): return rt.undefined_value
	js_text* flags = js_runtime_to_text(rt, js_runtime_get(rt, rx, c"flags"))
	if (flags == 0): return rt.undefined_value
	int state = JS_BRAND_REGEXP_ITERATOR
	if (js_rx_has_unit(flags, 'g')): state = state | JS_RX_ITER_GLOBAL
	if (js_rx_has_unit(flags, 'u')): state = state | JS_RX_ITER_UNICODE
	js_value* flag_value = js_runtime_string(rt, flags)
	js_text_free(flags)
	js_value* matcher = js_rx_construct(rt, constructor, rx, flag_value)
	if (matcher == 0): return rt.undefined_value
	int last_index = js_regexp_last_index(rt, rx)
	js_rx_put_index(rt, matcher, last_index)
	if (rt.completion.status != 0): return rt.undefined_value
	js_value* iterator = js_runtime_alloc(rt, 5)
	if (iterator == rt.undefined_value): return iterator
	iterator.prototype = rt.regexp_iterator_prototype
	iterator.builtin_state = state
	iterator.this_value = matcher
	iterator.text = js_text_clone(subject.text)
	return iterator


# %RegExpStringIteratorPrototype%.next.
js_value* js_rx_iterator_next(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_runtime_object(receiver) == 0 || (receiver.builtin_state & 3) != JS_BRAND_REGEXP_ITERATOR): return js_runtime_type_error(rt, c"RegExp String Iterator next requires a RegExp String Iterator")
	if (receiver.builtin_state & JS_RX_ITER_DONE): return js_runtime_iter_result(rt, rt.undefined_value, 1)
	js_value* subject = js_runtime_string(rt, receiver.text)
	js_value* rx = receiver.this_value
	js_value* match = js_regexp_exec_generic(rt, rx, subject)
	if (rt.completion.status != 0): return rt.undefined_value
	if (match.kind == 1):
		receiver.builtin_state = receiver.builtin_state | JS_RX_ITER_DONE
		return js_runtime_iter_result(rt, rt.undefined_value, 1)
	if (receiver.builtin_state & JS_RX_ITER_GLOBAL):
		js_text* matched = js_rx_match_text(rt, match)
		if (matched == 0): return rt.undefined_value
		if (matched.units.length == 0): js_rx_advance_empty(rt, rx, subject, (receiver.builtin_state & JS_RX_ITER_UNICODE) != 0)
		js_text_free(matched)
		if (rt.completion.status != 0): return rt.undefined_value
	else: receiver.builtin_state = receiver.builtin_state | JS_RX_ITER_DONE
	return js_runtime_iter_result(rt, match, 0)


# RegExp.prototype[Symbol.*]: 1 match, 2 matchAll, 3 replace, 4 search, 5 split.
js_value* js_rx_symbol_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	int operation = cast(int, context)
	if (js_runtime_object(receiver) == 0): return js_runtime_type_error(rt, c"RegExp Symbol method requires an object receiver")
	js_value* subject = js_runtime_to_string_value(rt, js_rx_argument(rt, args, 0))
	if (rt.completion.status != 0): return rt.undefined_value
	if (operation == 1): return js_rx_symbol_match(rt, receiver, subject)
	if (operation == 2): return js_rx_symbol_match_all(rt, receiver, subject)
	if (operation == 3): return js_rx_symbol_replace(rt, receiver, subject, js_rx_argument(rt, args, 1))
	if (operation == 4): return js_rx_symbol_search(rt, receiver, subject)
	return js_rx_symbol_split(rt, receiver, subject, js_rx_argument(rt, args, 1))


js_value* js_rx_species_getter(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	return receiver


# thisStringValue for String.prototype.toString and valueOf.
js_value* js_string_value_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (receiver.kind == 4): return receiver
	if (js_runtime_object(receiver) && receiver.builtin_state == JS_BRAND_STRING): return js_runtime_string(rt, receiver.text)
	return js_runtime_type_error(rt, c"String.prototype method requires a string")


# SplitMatch with a string separator: whole-separator comparison at q.
int js_string_split_match(list[int] units, int q, list[int] separator):
	if (q + separator.length > units.length): return -1
	for i in range(separator.length):
		if (units[q + i] != separator[i]): return -1
	return q + separator.length


js_value* js_string_split(js_runtime* rt, js_value* subject, js_value* separator, js_value* limit):
	js_value* array = js_runtime_alloc(rt, 6)
	int lim = (1 << 32) - 1
	if (limit.kind != 0): lim = js_runtime_to_uint32(rt, limit)
	if (rt.completion.status != 0): return rt.undefined_value
	js_text* text = js_runtime_to_text(rt, separator)
	if (text == 0): return rt.undefined_value
	list[int] units = subject.text.units
	list[int] needle = text.units
	if (lim == 0):
		js_text_free(text)
		return array
	if (separator.kind == 0):
		js_text_free(text)
		js_runtime_array_append(rt, array, subject)
		return array
	int size = units.length
	if (size == 0):
		if (needle.length != 0): js_runtime_array_append(rt, array, subject)
		js_text_free(text)
		return array
	int p = 0
	int q = 0
	while (q != size && js_runtime_compat_step(rt)):
		if (js_rx_charge(rt, needle.length) == 0): break
		int e = js_string_split_match(units, q, needle)
		if (e < 0 || e == p):
			q = q + 1
			continue
		js_runtime_array_append(rt, array, js_rx_substring(rt, units, p, q))
		if (array.array_length == lim): break
		p = e
		q = p
	if (rt.completion.status == 0 && array.array_length != lim): js_runtime_array_append(rt, array, js_rx_substring(rt, units, p, size))
	js_text_free(text)
	return array


# String.prototype.replace with a non-RegExp pattern: the first occurrence.
js_value* js_string_replace(js_runtime* rt, js_value* subject, js_value* search_value, js_value* replace_value):
	js_text* needle = js_runtime_to_text(rt, search_value)
	if (needle == 0): return rt.undefined_value
	int functional = js_runtime_callable(replace_value)
	js_text* template = 0
	if (functional == 0):
		template = js_runtime_to_text(rt, replace_value)
		if (template == 0):
			js_text_free(needle)
			return rt.undefined_value
	list[int] units = subject.text.units
	int position = -1
	for i in range(units.length - needle.units.length + 1):
		if (js_runtime_compat_step(rt) == 0 || js_rx_charge(rt, needle.units.length) == 0): break
		if (js_string_split_match(units, i, needle.units) >= 0):
			position = i
			break
	js_value* value = rt.undefined_value
	if (rt.completion.status == 0 && position < 0): value = subject
	else if (rt.completion.status == 0):
		js_text* replacement = 0
		if (functional):
			list[js_value*] arguments = new list[js_value*]
			arguments.push(js_runtime_string(rt, needle))
			arguments.push(js_runtime_number(rt, cast(float64, position)))
			arguments.push(subject)
			js_value* result = js_runtime_call_receiver(rt, replace_value, rt.undefined_value, arguments)
			__w_list_free(cast(__w_list*, arguments))
			if (rt.completion.status == 0): replacement = js_runtime_to_text(rt, result)
		else:
			list[js_value*] captures = new list[js_value*]
			replacement = js_rx_substitution(rt, needle, subject.text, position, captures, rt.undefined_value, template)
			__w_list_free(cast(__w_list*, captures))
		if (replacement != 0):
			js_text* out = js_text_new()
			js_rx_append(rt, out, units, 0, position)
			js_rx_append(rt, out, replacement.units, 0, replacement.units.length)
			js_rx_append(rt, out, units, position + needle.units.length, units.length)
			if (rt.completion.status == 0): value = js_runtime_string(rt, out)
			js_text_free(out)
			js_text_free(replacement)
	js_text_free(template)
	js_text_free(needle)
	return value


# String.prototype: 1 match, 2 matchAll, 3 replace, 4 search, 5 split.
js_value* js_string_regexp_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	int operation = cast(int, context)
	if (receiver.kind == 0 || receiver.kind == 1): return js_runtime_type_error(rt, c"String.prototype method called on null or undefined")
	js_value* pattern = js_rx_argument(rt, args, 0)
	js_value* second = js_rx_argument(rt, args, 1)
	int symbol = JS_SYMBOL_MATCH
	if (operation == 2): symbol = JS_SYMBOL_MATCH_ALL
	if (operation == 3): symbol = JS_SYMBOL_REPLACE
	if (operation == 4): symbol = JS_SYMBOL_SEARCH
	if (operation == 5): symbol = JS_SYMBOL_SPLIT
	if (pattern.kind != 0 && pattern.kind != 1):
		js_value* method = js_runtime_get_symbol_method(rt, pattern, symbol)
		if (rt.completion.status != 0): return rt.undefined_value
		if (method != 0):
			list[js_value*] arguments = new list[js_value*]
			arguments.push(receiver)
			if (operation == 3 || operation == 5): arguments.push(second)
			js_value* result = js_runtime_call_receiver(rt, method, pattern, arguments)
			__w_list_free(cast(__w_list*, arguments))
			return result
	js_value* subject = js_runtime_to_string_value(rt, receiver)
	if (rt.completion.status != 0): return rt.undefined_value
	if (operation == 3): return js_string_replace(rt, subject, pattern, second)
	if (operation == 5): return js_string_split(rt, subject, pattern, second)
	js_value* flags = rt.undefined_value
	if (operation == 2): flags = js_runtime_string_value(rt, c"g")
	js_value* rx = js_regexp_create(rt, pattern, flags)
	if (rt.completion.status != 0): return rt.undefined_value
	js_text* key = js_symbol_key(symbol)
	js_value* method = js_runtime_member_read(rt, rx, key)
	js_text_free(key)
	if (rt.completion.status != 0): return rt.undefined_value
	return js_runtime_call1(rt, method, rx, subject)


void js_rx_symbol_define(js_runtime* rt, js_value* object, int id, int operation, js_host_receiver_function* callback):
	js_runtime_define_symbol_method(rt, object, id, js_runtime_host_callable(rt, cast(void*, operation), callback))


void js_runtime_install_regexp_methods(js_runtime* rt):
	if (rt.regexp_prototype == 0 || rt.regexp_prototype == rt.undefined_value || rt.symbols.length < JS_SYMBOL_WELL_KNOWN): return
	js_rx_symbol_define(rt, rt.regexp_prototype, JS_SYMBOL_MATCH, 1, js_rx_symbol_method)
	js_rx_symbol_define(rt, rt.regexp_prototype, JS_SYMBOL_MATCH_ALL, 2, js_rx_symbol_method)
	js_rx_symbol_define(rt, rt.regexp_prototype, JS_SYMBOL_REPLACE, 3, js_rx_symbol_method)
	js_rx_symbol_define(rt, rt.regexp_prototype, JS_SYMBOL_SEARCH, 4, js_rx_symbol_method)
	js_rx_symbol_define(rt, rt.regexp_prototype, JS_SYMBOL_SPLIT, 5, js_rx_symbol_method)
	if (rt.regexp_constructor != 0):
		js_value* getter = js_runtime_host_callable(rt, 0, js_rx_species_getter)
		js_text* key = js_symbol_key(JS_SYMBOL_SPECIES)
		js_runtime_define_accessor(rt, rt.regexp_constructor, key, getter, 0, 0, 1)
		js_text_free(key)
	rt.regexp_iterator_prototype = js_runtime_alloc(rt, 5)
	if (rt.regexp_iterator_prototype == rt.undefined_value): return
	js_runtime_collection_method(rt, rt.regexp_iterator_prototype, c"next", 0, js_rx_iterator_next)
	js_rx_symbol_define(rt, rt.regexp_iterator_prototype, JS_SYMBOL_ITERATOR, 0, js_symbol_iterator_self)
	js_text* tag = js_runtime_key(c"RegExp String Iterator")
	js_text* key = js_symbol_key(JS_SYMBOL_TO_STRING_TAG)
	js_runtime_define_data(rt, rt.regexp_iterator_prototype, key, js_runtime_string(rt, tag), 0, 0, 1)
	js_text_free(key)
	js_text_free(tag)
	js_runtime_collection_method(rt, rt.string_prototype, c"match", 1, js_string_regexp_method)
	js_runtime_collection_method(rt, rt.string_prototype, c"matchAll", 2, js_string_regexp_method)
	js_runtime_collection_method(rt, rt.string_prototype, c"replace", 3, js_string_regexp_method)
	js_runtime_collection_method(rt, rt.string_prototype, c"search", 4, js_string_regexp_method)
	js_runtime_collection_method(rt, rt.string_prototype, c"split", 5, js_string_regexp_method)
	js_runtime_collection_method(rt, rt.string_prototype, c"toString", 0, js_string_value_method)
	js_runtime_collection_method(rt, rt.string_prototype, c"valueOf", 0, js_string_value_method)
