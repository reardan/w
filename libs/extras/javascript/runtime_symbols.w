# Symbols, the ECMAScript type conversions, Function.prototype.call/apply and
# the iterator protocol for the embedded interpreter (ECMA-262 2020 sec-7.1,
# sec-symbol-objects, sec-operations-on-iterator-objects).
#
# A symbol is a value of kind 11. Its property key is a js_text holding the
# single code unit -id, which no string can contain (string values only hold
# units 0..65535), so symbol-keyed properties share the ordinary property
# list without colliding with string keys. Well-known symbols have ids 1..13;
# Symbol() allocates fresh ids above them. The description is owned in key.
import libs.extras.javascript.runtime


const int JS_SYMBOL_ITERATOR = 1
const int JS_SYMBOL_ASYNC_ITERATOR = 2
const int JS_SYMBOL_HAS_INSTANCE = 3
const int JS_SYMBOL_IS_CONCAT_SPREADABLE = 4
const int JS_SYMBOL_MATCH = 5
const int JS_SYMBOL_MATCH_ALL = 6
const int JS_SYMBOL_REPLACE = 7
const int JS_SYMBOL_SEARCH = 8
const int JS_SYMBOL_SPECIES = 9
const int JS_SYMBOL_SPLIT = 10
const int JS_SYMBOL_TO_PRIMITIVE = 11
const int JS_SYMBOL_TO_STRING_TAG = 12
const int JS_SYMBOL_UNSCOPABLES = 13
const int JS_SYMBOL_WELL_KNOWN = 13


char* js_symbol_name(int id):
	if (id == JS_SYMBOL_ITERATOR): return c"iterator"
	if (id == JS_SYMBOL_ASYNC_ITERATOR): return c"asyncIterator"
	if (id == JS_SYMBOL_HAS_INSTANCE): return c"hasInstance"
	if (id == JS_SYMBOL_IS_CONCAT_SPREADABLE): return c"isConcatSpreadable"
	if (id == JS_SYMBOL_MATCH): return c"match"
	if (id == JS_SYMBOL_MATCH_ALL): return c"matchAll"
	if (id == JS_SYMBOL_REPLACE): return c"replace"
	if (id == JS_SYMBOL_SEARCH): return c"search"
	if (id == JS_SYMBOL_SPECIES): return c"species"
	if (id == JS_SYMBOL_SPLIT): return c"split"
	if (id == JS_SYMBOL_TO_PRIMITIVE): return c"toPrimitive"
	if (id == JS_SYMBOL_TO_STRING_TAG): return c"toStringTag"
	return c"unscopables"


# Owned property key of symbol id.
js_text* js_symbol_key(int id):
	js_text* key = js_text_new()
	key.units.push(-id)
	return key


js_value* js_symbol_new(js_runtime* rt, js_text* description):
	js_value* symbol = js_runtime_alloc(rt, 11)
	if (symbol == rt.undefined_value): return symbol
	rt.symbol_next = rt.symbol_next + 1
	symbol.text = js_symbol_key(rt.symbol_next)
	if (description != 0): symbol.key = js_text_clone(description)
	return symbol


js_value* js_runtime_well_known(js_runtime* rt, int id):
	return rt.symbols[id - 1]


# SymbolDescriptiveString: "Symbol(" + description + ")".
js_text* js_symbol_descriptive(js_value* symbol):
	js_text* text = js_runtime_key(c"Symbol(")
	if (symbol.key != 0):
		for int unit in symbol.key.units: text.units.push(unit)
	text.units.push(')')
	return text


js_value* js_runtime_type_error(js_runtime* rt, char* message):
	js_runtime_fail(rt, 2, message)
	return rt.undefined_value


int js_runtime_is_constructor(js_runtime* rt, js_value* value):
	if (value == 0 || js_runtime_object(value) == 0): return 0
	if (value == rt.promise_constructor || value.binary_constructor != 0 || (value.kind == 9 && value.host_construct)): return 1
	return js_runtime_constructible(value)


js_value* js_runtime_string_value(js_runtime* rt, char* raw):
	js_text* text = js_runtime_key(raw)
	js_value* value = js_runtime_string(rt, text)
	js_text_free(text)
	return value


js_value* js_runtime_call0(js_runtime* rt, js_value* callable, js_value* receiver):
	list[js_value*] args = new list[js_value*]
	js_value* result = js_runtime_call_receiver(rt, callable, receiver, args)
	__w_list_free(cast(__w_list*, args))
	return result


js_value* js_runtime_call1(js_runtime* rt, js_value* callable, js_value* receiver, js_value* argument):
	list[js_value*] args = new list[js_value*]
	args.push(argument)
	js_value* result = js_runtime_call_receiver(rt, callable, receiver, args)
	__w_list_free(cast(__w_list*, args))
	return result


# GetV(value, key) for any value; undefined and null throw TypeError.
js_value* js_runtime_get_value(js_runtime* rt, js_value* value, js_text* key):
	if (value.kind == 0 || value.kind == 1): return js_runtime_type_error(rt, c"cannot read a property of null or undefined")
	return js_runtime_member_read(rt, value, key)


# GetMethod: null for an absent (undefined/null) method, TypeError when the
# value is present but not callable.
js_value* js_runtime_get_method(js_runtime* rt, js_value* value, js_text* key):
	js_value* method = js_runtime_get_value(rt, value, key)
	if (rt.completion.status != 0 || method.kind == 0 || method.kind == 1): return 0
	if (js_runtime_callable(method) == 0):
		js_runtime_fail(rt, 2, c"property is not a function")
		return 0
	return method


js_value* js_runtime_get_symbol_method(js_runtime* rt, js_value* value, int id):
	js_text* key = js_symbol_key(id)
	js_value* method = js_runtime_get_method(rt, value, key)
	js_text_free(key)
	return method


# True when key is found on the object or its prototype chain (no getters run).
int js_runtime_has_property(js_runtime* rt, js_value* object, js_text* key):
	int depth = 0
	while (object != 0 && depth < rt.max_depth):
		if (object.host_get != 0 || js_runtime_property(object, key) != 0): return 1
		object = object.prototype
		depth = depth + 1
	return 0


# Array.prototype.join(","): holes, undefined and null join as empty.
js_text* js_runtime_array_join(js_runtime* rt, js_value* array):
	js_text* text = js_text_new()
	int length = array.array_length
	for i in range(length):
		if (js_runtime_compat_step(rt) == 0): break
		if (i > 0): text.units.push(',')
		js_value* item = js_runtime_index_get(rt, array, i)
		if (rt.completion.status != 0 || item.kind == 0 || item.kind == 1): continue
		js_text* part = js_runtime_to_text(rt, item)
		if (part == 0): break
		if (text.units.length + part.units.length > rt.max_properties):
			js_text_free(part)
			js_runtime_fail(rt, 5, c"JavaScript string length limit")
			break
		for int unit in part.units: text.units.push(unit)
		js_text_free(part)
	if (rt.completion.status != 0):
		js_text_free(text)
		return 0
	return text


# The runtime installs no Object.prototype, so an object whose prototype
# chain has no toString behaves as if it inherited the missing intrinsic:
# Array.prototype.toString (join) for arrays, Object.prototype.toString
# ("[object Tag]") otherwise. Function source text is not retained.
js_value* js_runtime_intrinsic_text(js_runtime* rt, js_value* object):
	if (object.kind == 6):
		js_text* joined = js_runtime_array_join(rt, object)
		if (joined == 0): return rt.undefined_value
		js_value* value = js_runtime_string(rt, joined)
		js_text_free(joined)
		return value
	if (object.kind == 7 || object.kind == 9):
		js_runtime_fail(rt, 6, c"function source text conversion is outside the runtime subset")
		return rt.undefined_value
	js_text* text = js_runtime_key(c"[object ")
	js_text* tag_key = js_symbol_key(JS_SYMBOL_TO_STRING_TAG)
	js_value* tag = js_runtime_member_read(rt, object, tag_key)
	js_text_free(tag_key)
	if (rt.completion.status != 0):
		js_text_free(text)
		return rt.undefined_value
	if (tag.kind == 4):
		for int unit in tag.text.units: text.units.push(unit)
	else:
		char* name = c"Object"
		if (object.intrinsic_error_name[0] != 0 || (object.prototype != 0 && rt.error_prototypes.length > 0 && object.prototype == rt.error_prototypes[0])): name = c"Error"
		if (object.regexp != 0): name = c"RegExp"
		if (object.builtin_state == 1): name = c"String"
		for i in range(strlen(name)): text.units.push(name[i])
	text.units.push(']')
	js_value* value = js_runtime_string(rt, text)
	js_text_free(text)
	return value


# ToPrimitive (sec-toprimitive). hint: 0 default, 1 number, 2 string.
js_value* js_runtime_to_primitive(js_runtime* rt, js_value* value, int hint):
	if (js_runtime_object(value) == 0): return value
	js_value* exotic = js_runtime_get_symbol_method(rt, value, JS_SYMBOL_TO_PRIMITIVE)
	if (rt.completion.status != 0): return rt.undefined_value
	if (exotic != 0):
		char* name = c"default"
		if (hint == 1): name = c"number"
		if (hint == 2): name = c"string"
		js_value* result = js_runtime_call1(rt, exotic, value, js_runtime_string_value(rt, name))
		if (rt.completion.status != 0): return rt.undefined_value
		if (js_runtime_object(result)): return js_runtime_type_error(rt, c"Symbol.toPrimitive returned an object")
		return result
	# OrdinaryToPrimitive: toString first for string hints, valueOf first
	# otherwise. A method absent from the whole chain is a missing intrinsic.
	int missing_text = 0
	for i in range(2):
		char* name = c"valueOf"
		if ((i == 0) == (hint == 2)): name = c"toString"
		js_text* key = js_runtime_key(name)
		int present = js_runtime_has_property(rt, value, key)
		js_value* method = js_runtime_member_read(rt, value, key)
		js_text_free(key)
		if (rt.completion.status != 0): return rt.undefined_value
		if (present == 0 && strcmp(name, c"toString") == 0): missing_text = 1
		if (js_runtime_callable(method)):
			js_value* result = js_runtime_call0(rt, method, value)
			if (rt.completion.status != 0): return rt.undefined_value
			if (js_runtime_object(result) == 0): return result
	if (missing_text): return js_runtime_intrinsic_text(rt, value)
	return js_runtime_type_error(rt, c"cannot convert object to primitive value")


# ToString; returns owned text, or 0 with an abrupt completion.
js_text* js_runtime_to_text(js_runtime* rt, js_value* value):
	if (rt.completion.status != 0): return 0
	if (value.kind == 11):
		js_runtime_fail(rt, 2, c"cannot convert a Symbol value to a string")
		return 0
	if (js_runtime_object(value)):
		js_value* primitive = js_runtime_to_primitive(rt, value, 2)
		if (rt.completion.status != 0): return 0
		return js_runtime_to_text(rt, primitive)
	if (value.kind > 4 && value.kind != 10):
		js_runtime_fail(rt, 6, c"value string conversion is outside the runtime subset")
		return 0
	return js_runtime_primitive_text(rt, value)


js_value* js_runtime_to_string_value(js_runtime* rt, js_value* value):
	if (value.kind == 4): return value
	js_text* text = js_runtime_to_text(rt, value)
	if (text == 0): return rt.undefined_value
	js_value* result = js_runtime_string(rt, text)
	js_text_free(text)
	return result


# ToPropertyKey: symbols keep their key, every other value converts to text.
js_text* js_runtime_property_key(js_runtime* rt, js_value* value):
	if (value.kind == 4): return js_text_clone(value.text)
	if (value.kind == 11): return js_text_clone(value.text)
	if (js_runtime_object(value)):
		js_value* primitive = js_runtime_to_primitive(rt, value, 2)
		if (rt.completion.status != 0): return 0
		return js_runtime_property_key(rt, primitive)
	return js_runtime_to_text(rt, value)


int js_runtime_white_space(int ch):
	return ch == 9 || ch == 10 || ch == 11 || ch == 12 || ch == 13 || ch == 32 || ch == 160 || ch == 5760 || (ch >= 8192 && ch <= 8202) || ch == 8232 || ch == 8233 || ch == 8239 || ch == 8287 || ch == 12288 || ch == 65279


# StringToNumber (sec-tonumber-applied-to-the-string-type): trimmed
# StrDecimalLiteral, Infinity and unsigned 0x/0o/0b integers; otherwise NaN.
float64 js_runtime_string_number(js_text* text):
	float64 nan = float64_from_bits((0x7ff << 52) | 1)
	float64 infinity = float64_from_bits(0x7ff << 52)
	int start = 0
	int end = text.units.length
	while (start < end && js_runtime_white_space(text.units[start])): start = start + 1
	while (end > start && js_runtime_white_space(text.units[end - 1])): end = end - 1
	if (start == end): return 0.0
	char* raw = cast(char*, malloc(end - start + 1))
	for i in range(start, end):
		int unit = text.units[i]
		if (unit <= 0 || unit > 127):
			free(raw)
			return nan
		raw[i - start] = unit
	raw[end - start] = 0
	int length = end - start
	float64 result = nan
	int radix = 0
	if (length > 2 && raw[0] == '0'):
		if (raw[1] == 'x' || raw[1] == 'X'): radix = 16
		if (raw[1] == 'o' || raw[1] == 'O'): radix = 8
		if (raw[1] == 'b' || raw[1] == 'B'): radix = 2
	if (radix != 0):
		result = 0.0
		for i in range(2, length):
			int digit = -1
			if (raw[i] >= '0' && raw[i] <= '9'): digit = raw[i] - '0'
			if (raw[i] >= 'a' && raw[i] <= 'f'): digit = raw[i] - 'a' + 10
			if (raw[i] >= 'A' && raw[i] <= 'F'): digit = raw[i] - 'A' + 10
			if (digit < 0 || digit >= radix):
				result = nan
				break
			result = result * cast(float64, radix) + cast(float64, digit)
		free(raw)
		return result
	int at = 0
	int negative = 0
	if (raw[0] == '+' || raw[0] == '-'):
		negative = raw[0] == '-'
		at = 1
	if (strcmp(raw + at, c"Infinity") == 0):
		free(raw)
		if (negative): return -infinity
		return infinity
	# StrUnsignedDecimalLiteral: digits [. digits] [e[+-]digits], at least
	# one digit in the mantissa.
	int i = at
	int digits = 0
	while (raw[i] >= '0' && raw[i] <= '9'):
		i = i + 1
		digits = digits + 1
	if (raw[i] == '.'):
		i = i + 1
		while (raw[i] >= '0' && raw[i] <= '9'):
			i = i + 1
			digits = digits + 1
	int valid = digits > 0
	if (valid && (raw[i] == 'e' || raw[i] == 'E')):
		i = i + 1
		if (raw[i] == '+' || raw[i] == '-'): i = i + 1
		int exponent = 0
		while (raw[i] >= '0' && raw[i] <= '9'):
			i = i + 1
			exponent = exponent + 1
		valid = exponent > 0
	if (valid && i == length):
		# parse_float64 rejects a leading '.' or a trailing '.', so normalize.
		string_builder* normal = string_new()
		for j in range(at, length):
			if (raw[j] == '.' && (j == at || raw[j - 1] < '0' || raw[j - 1] > '9')): string_append_char(normal, '0')
			if (raw[j] == '.' && (j + 1 >= length || raw[j + 1] < '0' || raw[j + 1] > '9')): continue
			string_append_char(normal, raw[j])
		int consumed = 0
		result = parse_float64(normal.data, &consumed)
		if (consumed != normal.length): result = nan
		else if (negative): result = -result
		string_free(normal)
	free(raw)
	return result


# ToNumber; NaN with an abrupt completion on failure.
float64 js_runtime_to_number(js_runtime* rt, js_value* value):
	float64 nan = float64_from_bits((0x7ff << 52) | 1)
	if (rt.completion.status != 0): return nan
	if (value.kind == 3): return value.number
	if (value.kind == 0): return nan
	if (value.kind == 1): return 0.0
	if (value.kind == 2): return value.number
	if (value.kind == 4): return js_runtime_string_number(value.text)
	if (value.kind == 10 || value.kind == 11):
		js_runtime_fail(rt, 2, c"cannot convert a BigInt or Symbol value to a number")
		return nan
	if (js_runtime_object(value)):
		js_value* primitive = js_runtime_to_primitive(rt, value, 1)
		if (rt.completion.status != 0): return nan
		return js_runtime_to_number(rt, primitive)
	js_runtime_fail(rt, 6, c"value numeric conversion is outside the runtime subset")
	return nan


# ToInteger (ES2020): NaN is 0, otherwise truncation; infinities stay.
float64 js_runtime_to_integer(js_runtime* rt, js_value* value):
	float64 number = js_runtime_to_number(rt, value)
	if (f64is_nan(number)): return 0.0
	float64 infinity = float64_from_bits(0x7ff << 52)
	if (number == infinity || number == -infinity): return number
	return js_builtin_trunc(number) + 0.0


# ToLength clamped to the interpreter's word size: [0, 2^53 - 1].
int js_runtime_to_length(js_runtime* rt, js_value* value):
	float64 number = js_runtime_to_integer(rt, value)
	if (number <= 0.0): return 0
	if (number >= 9007199254740991.0): return (1 << 53) - 1
	return cast(int, number)


# ToUint32, as a nonnegative word.
int js_runtime_to_uint32(js_runtime* rt, js_value* value):
	float64 number = js_runtime_to_number(rt, value)
	if (rt.completion.status != 0): return 0
	int mask = (1 << 32) - 1
	return js_runtime_int32(number) & mask


# Clamp an integer-valued double into [0, limit].
int js_runtime_clamp(float64 number, int limit):
	if (number <= 0.0): return 0
	if (number >= cast(float64, limit)): return limit
	return cast(int, number)


js_value* js_runtime_iter_result(js_runtime* rt, js_value* value, int done):
	js_value* result = js_runtime_alloc(rt, 5)
	if (result == rt.undefined_value): return result
	js_runtime_set(rt, result, c"value", value)
	js_runtime_set(rt, result, c"done", js_runtime_boolean(rt, done))
	return result


# GetIterator (sync). The returned record is an internal object holding the
# iterator in this_value and its cached next method in getter.
js_value* js_runtime_iterator_open(js_runtime* rt, js_value* value):
	if (rt.completion.status != 0): return 0
	if (value.kind == 0 || value.kind == 1):
		js_runtime_fail(rt, 2, c"value is not iterable")
		return 0
	js_value* method = js_runtime_get_symbol_method(rt, value, JS_SYMBOL_ITERATOR)
	if (rt.completion.status != 0): return 0
	if (method == 0):
		if (value.kind == 2 || value.kind == 3 || value.kind == 10 || value.kind == 11): js_runtime_fail(rt, 2, c"value is not iterable")
		else if (js_runtime_object(value)): js_runtime_fail(rt, 2, c"value is not iterable")
		else: js_runtime_fail(rt, 6, c"iteration requires array, string or iterable object")
		return 0
	js_value* iterator = js_runtime_call0(rt, method, value)
	if (rt.completion.status != 0): return 0
	if (js_runtime_object(iterator) == 0):
		js_runtime_fail(rt, 2, c"iterator is not an object")
		return 0
	js_text* key = js_runtime_key(c"next")
	js_value* next = js_runtime_member_read(rt, iterator, key)
	js_text_free(key)
	if (rt.completion.status != 0): return 0
	js_value* record = js_runtime_alloc(rt, 5)
	if (record == rt.undefined_value): return 0
	record.this_value = iterator
	if (js_runtime_callable(next)): record.getter = next
	return record


# IteratorStep + IteratorValue: the next value, or 0 when done or abrupt.
js_value* js_runtime_iterator_step(js_runtime* rt, js_value* record):
	if (rt.completion.status != 0): return 0
	if (record.getter == 0):
		js_runtime_fail(rt, 2, c"iterator next is not a function")
		return 0
	js_value* result = js_runtime_call0(rt, record.getter, record.this_value)
	if (rt.completion.status != 0): return 0
	if (js_runtime_object(result) == 0):
		js_runtime_fail(rt, 2, c"iterator result is not an object")
		return 0
	js_value* done = js_runtime_get(rt, result, c"done")
	if (rt.completion.status != 0 || js_runtime_truth(done)): return 0
	return js_runtime_get(rt, result, c"value")


# IteratorClose for the active completion: a throw completion wins over any
# result of return(); otherwise return() errors and non-object results throw.
void js_runtime_iterator_close(js_runtime* rt, js_value* record):
	int status = rt.completion.status
	js_value* saved = rt.completion.value
	char* message = rt.completion.message
	js_node* target = rt.jump_target
	rt.completion.status = 0
	js_text* key = js_runtime_key(c"return")
	js_value* method = js_runtime_get_method(rt, record.this_value, key)
	js_text_free(key)
	js_value* result = rt.undefined_value
	if (method != 0 && rt.completion.status == 0): result = js_runtime_call0(rt, method, record.this_value)
	if (status == 2 || status == 5):
		rt.completion.status = status
		rt.completion.value = saved
		rt.completion.message = message
		return
	if (rt.completion.status != 0): return
	if (method != 0 && js_runtime_object(result) == 0):
		js_runtime_fail(rt, 2, c"iterator return result is not an object")
		return
	rt.completion.status = status
	rt.completion.value = saved
	rt.completion.message = message
	rt.jump_target = target


# Function.prototype.call (1) and apply (2).
js_value* js_function_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (js_runtime_callable(receiver) == 0): return js_runtime_type_error(rt, c"Function.prototype method receiver is not callable")
	js_value* this_value = rt.undefined_value
	if (args.length > 0): this_value = args[0]
	list[js_value*] arguments = new list[js_value*]
	if (cast(int, context) == 1):
		for i in range(1, args.length): arguments.push(args[i])
	else if (args.length > 1 && args[1].kind != 0 && args[1].kind != 1):
		js_value* array = args[1]
		if (js_runtime_object(array) == 0):
			__w_list_free(cast(__w_list*, arguments))
			return js_runtime_type_error(rt, c"apply arguments are not an object")
		int length = js_runtime_to_length(rt, js_runtime_get(rt, array, c"length"))
		if (length > rt.max_properties):
			__w_list_free(cast(__w_list*, arguments))
			js_runtime_fail(rt, 5, c"JavaScript host argument count limit")
			return rt.undefined_value
		for i in range(length):
			if (js_runtime_compat_step(rt) == 0): break
			arguments.push(js_runtime_index_get(rt, array, i))
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_runtime_call_receiver(rt, receiver, this_value, arguments)
	__w_list_free(cast(__w_list*, arguments))
	return result


# Symbol([description]); new Symbol() throws.
js_value* js_symbol_function(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	int constructing = rt.new_target != 0 && rt.new_target.host == cast(int, js_symbol_function)
	rt.new_target = 0
	if (constructing): return js_runtime_type_error(rt, c"Symbol is not a constructor")
	js_text* description = 0
	if (args.length > 0 && args[0].kind != 0):
		description = js_runtime_to_text(rt, args[0])
		if (description == 0): return rt.undefined_value
	js_value* symbol = js_symbol_new(rt, description)
	js_text_free(description)
	return symbol


# thisSymbolValue for Symbol.prototype: 1 toString, 2 valueOf, 3 description.
js_value* js_symbol_method(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (receiver.kind != 11): return js_runtime_type_error(rt, c"Symbol.prototype method requires a symbol")
	int operation = cast(int, context)
	if (operation == 2): return receiver
	if (operation == 3):
		if (receiver.key == 0): return rt.undefined_value
		return js_runtime_string(rt, receiver.key)
	js_text* text = js_symbol_descriptive(receiver)
	js_value* value = js_runtime_string(rt, text)
	js_text_free(text)
	return value


js_value* js_symbol_iterator_self(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	return receiver


void js_runtime_define_symbol_method(js_runtime* rt, js_value* object, int id, js_value* method):
	js_text* key = js_symbol_key(id)
	js_runtime_define_data(rt, object, key, method, 1, 0, 1)
	js_text_free(key)


void js_runtime_install_object(js_runtime* rt);


void js_runtime_install_symbols(js_runtime* rt):
	if (rt.function_prototype == rt.undefined_value): return
	js_runtime_collection_method(rt, rt.function_prototype, c"call", 1, js_function_method)
	js_runtime_collection_method(rt, rt.function_prototype, c"apply", 2, js_function_method)
	rt.symbol_prototype = js_runtime_alloc(rt, 5)
	js_value* constructor = js_runtime_host_callable(rt, 0, js_symbol_function)
	if (rt.symbol_prototype == rt.undefined_value || constructor == rt.undefined_value): return
	constructor.host_construct = 1
	for id in range(1, JS_SYMBOL_WELL_KNOWN + 1):
		char* name = js_symbol_name(id)
		js_text* description = js_runtime_key(c"Symbol.")
		for i in range(strlen(name)): description.units.push(name[i])
		js_value* symbol = js_symbol_new(rt, description)
		js_text_free(description)
		rt.symbols.push(symbol)
		js_text* key = js_runtime_key(name)
		js_runtime_define_data(rt, constructor, key, symbol, 0, 0, 0)
		js_text_free(key)
	js_text* key = js_runtime_key(c"prototype")
	js_runtime_define_data(rt, constructor, key, rt.symbol_prototype, 0, 0, 0)
	js_text_free(key)
	key = js_runtime_key(c"constructor")
	js_runtime_define_data(rt, rt.symbol_prototype, key, constructor, 1, 0, 1)
	js_text_free(key)
	js_runtime_collection_method(rt, rt.symbol_prototype, c"toString", 1, js_symbol_method)
	js_runtime_collection_method(rt, rt.symbol_prototype, c"valueOf", 2, js_symbol_method)
	js_value* getter = js_runtime_host_callable(rt, cast(void*, 3), js_symbol_method)
	key = js_runtime_key(c"description")
	js_runtime_define_accessor(rt, rt.symbol_prototype, key, getter, 0, 0, 1)
	js_text_free(key)
	js_runtime_define_symbol_method(rt, rt.symbol_prototype, JS_SYMBOL_TO_PRIMITIVE, js_runtime_host_callable(rt, cast(void*, 2), js_symbol_method))
	js_text* tag = js_runtime_key(c"Symbol")
	key = js_symbol_key(JS_SYMBOL_TO_STRING_TAG)
	js_runtime_define_data(rt, rt.symbol_prototype, key, js_runtime_string(rt, tag), 0, 0, 1)
	js_text_free(key)
	js_text_free(tag)
	js_runtime_set(rt, rt.global, c"Symbol", constructor)
	js_runtime_install_object(rt)


# A minimal Object global: Object(value)/new Object(), defineProperty,
# getOwnPropertyDescriptor and getPrototypeOf; plus Array.isArray. Other
# Object and Array statics remain outside the runtime subset.
int js_object_field(js_runtime* rt, js_value* descriptor, char* name, js_value** out):
	js_text* key = js_runtime_key(name)
	int present = js_runtime_has_property(rt, descriptor, key)
	*out = rt.undefined_value
	if (present): *out = js_runtime_member_read(rt, descriptor, key)
	js_text_free(key)
	return present && rt.completion.status == 0


js_value* js_runtime_fail_unsupported(js_runtime* rt);


# ToPropertyDescriptor plus ValidateAndApplyPropertyDescriptor: absent fields
# default to false/undefined on a new property and keep an existing value.
js_value* js_object_define(js_runtime* rt, js_value* object, js_value* name, js_value* descriptor):
	if (js_runtime_object(object) == 0): return js_runtime_type_error(rt, c"Object.defineProperty called on non-object")
	js_text* key = js_runtime_property_key(rt, name)
	if (key == 0): return rt.undefined_value
	if (js_runtime_object(descriptor) == 0):
		js_text_free(key)
		return js_runtime_type_error(rt, c"property descriptor must be an object")
	js_value* enumerable = 0
	js_value* configurable = 0
	js_value* value = 0
	js_value* writable = 0
	js_value* getter = 0
	js_value* setter = 0
	int has_enumerable = js_object_field(rt, descriptor, c"enumerable", &enumerable)
	int has_configurable = js_object_field(rt, descriptor, c"configurable", &configurable)
	int has_value = js_object_field(rt, descriptor, c"value", &value)
	int has_writable = js_object_field(rt, descriptor, c"writable", &writable)
	int has_get = js_object_field(rt, descriptor, c"get", &getter)
	int has_set = js_object_field(rt, descriptor, c"set", &setter)
	if (rt.completion.status != 0):
		js_text_free(key)
		return rt.undefined_value
	if ((has_get && getter.kind != 0 && js_runtime_callable(getter) == 0) || (has_set && setter.kind != 0 && js_runtime_callable(setter) == 0) || ((has_get || has_set) && (has_value || has_writable))):
		js_text_free(key)
		return js_runtime_type_error(rt, c"invalid property descriptor")
	js_value* current = js_runtime_property(object, key)
	int accessor = has_get || has_set
	if (accessor == 0 && has_value == 0 && has_writable == 0 && current != 0): accessor = current.accessor
	int enumerable_flag = 0
	int configurable_flag = 0
	int writable_flag = 0
	js_value* data = rt.undefined_value
	js_value* get_function = 0
	js_value* set_function = 0
	if (current != 0):
		enumerable_flag = current.enumerable
		configurable_flag = current.configurable
		if (current.accessor == accessor):
			writable_flag = current.writable
			data = current.value
			get_function = current.getter
			set_function = current.setter
	if (has_enumerable): enumerable_flag = js_runtime_truth(enumerable)
	if (has_configurable): configurable_flag = js_runtime_truth(configurable)
	if (has_writable): writable_flag = js_runtime_truth(writable)
	if (has_value): data = value
	if (has_get):
		get_function = 0
		if (getter.kind != 0): get_function = getter
	if (has_set):
		set_function = 0
		if (setter.kind != 0): set_function = setter
	int ok = 0
	int index = -1
	if (object.kind == 6): index = js_runtime_array_index(key)
	if (object.kind == 6 && js_runtime_key_is(key, c"length")):
		ok = accessor == 0 && (has_value == 0 || js_runtime_array_resize(rt, object, data))
	else: ok = js_runtime_define(rt, object, key, data, get_function, set_function, accessor, writable_flag, enumerable_flag, configurable_flag)
	if (ok && index >= object.array_length): object.array_length = index + 1
	js_text_free(key)
	if (rt.completion.status != 0): return rt.undefined_value
	if (ok == 0): return js_runtime_type_error(rt, c"cannot redefine property")
	return object


js_value* js_object_descriptor(js_runtime* rt, js_value* object, js_value* name):
	if (js_runtime_object(object) == 0): return js_runtime_type_error(rt, c"Object.getOwnPropertyDescriptor called on non-object")
	js_text* key = js_runtime_property_key(rt, name)
	if (key == 0): return rt.undefined_value
	js_value* property = js_runtime_property(object, key)
	js_value* result = rt.undefined_value
	if (property == 0 && object.kind == 6 && js_runtime_key_is(key, c"length")):
		result = js_runtime_alloc(rt, 5)
		js_runtime_set(rt, result, c"value", js_runtime_number(rt, cast(float64, object.array_length)))
		js_runtime_set(rt, result, c"writable", js_runtime_boolean(rt, 1))
		js_runtime_set(rt, result, c"enumerable", js_runtime_boolean(rt, 0))
		js_runtime_set(rt, result, c"configurable", js_runtime_boolean(rt, 0))
	else if (property != 0):
		result = js_runtime_alloc(rt, 5)
		if (property.accessor == 2):
			# Module namespace export: [[GetOwnProperty]] reads the live binding.
			js_value* current = js_runtime_binding_value(rt, property)
			if (rt.completion.status != 0):
				js_text_free(key)
				return rt.undefined_value
			js_runtime_set(rt, result, c"value", current)
			js_runtime_set(rt, result, c"writable", js_runtime_boolean(rt, 1))
		else if (property.accessor):
			js_value* getter = rt.undefined_value
			js_value* setter = rt.undefined_value
			if (property.getter != 0): getter = property.getter
			if (property.setter != 0): setter = property.setter
			js_runtime_set(rt, result, c"get", getter)
			js_runtime_set(rt, result, c"set", setter)
		else:
			js_runtime_set(rt, result, c"value", property.value)
			js_runtime_set(rt, result, c"writable", js_runtime_boolean(rt, property.writable))
		js_runtime_set(rt, result, c"enumerable", js_runtime_boolean(rt, property.enumerable))
		js_runtime_set(rt, result, c"configurable", js_runtime_boolean(rt, property.configurable))
	js_text_free(key)
	return result


# Object statics: 0 Object(value), 1 defineProperty, 2 getOwnPropertyDescriptor,
# 3 getPrototypeOf, 4 Array.isArray.
js_value* js_object_function(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	int operation = cast(int, context)
	rt.new_target = 0
	js_value* first = rt.undefined_value
	js_value* second = rt.undefined_value
	if (args.length > 0): first = args[0]
	if (args.length > 1): second = args[1]
	if (operation == 1):
		js_value* third = rt.undefined_value
		if (args.length > 2): third = args[2]
		return js_object_define(rt, first, second, third)
	if (operation == 2): return js_object_descriptor(rt, first, second)
	if (operation == 3):
		if (first.kind == 0 || first.kind == 1): return js_runtime_type_error(rt, c"Object.getPrototypeOf called on null or undefined")
		js_value* prototype = 0
		if (js_runtime_object(first)): prototype = first.prototype
		else if (first.kind == 4): prototype = rt.string_prototype
		else if (first.kind == 11): prototype = rt.symbol_prototype
		else: return js_runtime_fail_unsupported(rt)
		if (prototype == 0): return js_runtime_alloc(rt, 1)
		return prototype
	if (operation == 4): return js_runtime_boolean(rt, first.kind == 6)
	if (js_runtime_object(first)): return first
	if (first.kind == 4):
		list[js_value*] wrapped = new list[js_value*]
		wrapped.push(first)
		js_value* wrapper = js_runtime_construct(rt, rt.string_constructor, wrapped, rt.string_constructor)
		__w_list_free(cast(__w_list*, wrapped))
		return wrapper
	if (first.kind != 0 && first.kind != 1): return js_runtime_fail_unsupported(rt)
	return js_runtime_alloc(rt, 5)


js_value* js_runtime_fail_unsupported(js_runtime* rt):
	js_runtime_fail(rt, 6, c"primitive wrapper objects are outside the runtime subset")
	return rt.undefined_value


void js_runtime_install_object(js_runtime* rt):
	js_value* object = js_runtime_host_callable(rt, 0, js_object_function)
	js_value* array = js_runtime_alloc(rt, 5)
	if (object == rt.undefined_value || array == rt.undefined_value): return
	object.host_construct = 1
	js_runtime_collection_method(rt, object, c"defineProperty", 1, js_object_function)
	js_runtime_collection_method(rt, object, c"getOwnPropertyDescriptor", 2, js_object_function)
	js_runtime_collection_method(rt, object, c"getPrototypeOf", 3, js_object_function)
	js_runtime_collection_method(rt, array, c"isArray", 4, js_object_function)
	js_text* key = js_runtime_key(c"prototype")
	js_runtime_define_data(rt, array, key, rt.array_prototype, 0, 0, 0)
	js_text_free(key)
	key = js_runtime_key(c"constructor")
	js_runtime_define_data(rt, rt.array_prototype, key, array, 1, 0, 1)
	js_text_free(key)
	js_runtime_set(rt, rt.global, c"Object", object)
	js_runtime_set(rt, rt.global, c"Array", array)
