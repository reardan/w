/*
Acceptance probe for the JS builtins port (docs/projects/js_builtins_port_plan.md).
Each row is a JS boolean expression evaluated in a fresh realm; PASS needs a
normal completion with value true. Usage: bin/port_probe [cluster|all] [--strict]
Not a wbuild target: it is a progress report, nonzero exit only with --strict.
Clusters may append rows to their own section only.
*/
import lib.args
import libs.extras.javascript.runtime


int probe_failures = 0


void probe_row(char* cluster, char* want, char* name, char* source):
	if (strcmp(want, c"all") != 0 && strcmp(want, cluster) != 0): return
	js_runtime* rt = js_runtime_new()
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	int ok = result.status == 0 && result.value.kind == 2 && result.value.number != 0.0
	if (ok): print(c"PASS ")
	else:
		print(c"FAIL ")
		probe_failures = probe_failures + 1
	print(cluster)
	print(c" ")
	println(name)
	js_runtime_free(rt)


void probe_object(char* w):
	probe_row(c"object", w, c"Object.keys", c"Object.keys({a:1,b:2}).length === 2;")
	probe_row(c"object", w, c"Object.freeze", c"var o = Object.freeze({a:1}); o.a = 2; o.a === 1 && Object.isFrozen(o);")
	probe_row(c"object", w, c"JSON.stringify", c"JSON.stringify({a:[1,2],b:'x'}) === '{\"a\":[1,2],\"b\":\"x\"}';")
	probe_row(c"object", w, c"JSON.parse", c"JSON.parse('{\"a\":[1,2]}').a[1] === 2;")
	probe_row(c"object", w, c"Reflect.ownKeys", c"Reflect.ownKeys({a:1,b:2}).length === 2;")
	probe_row(c"object", w, c"Reflect.construct", c"function F(){ this.x = 1; } Reflect.construct(F, []).x === 1;")


void probe_array(char* w):
	probe_row(c"array", w, c"push/pop", c"var a = [1]; a.push(2); a.pop() === 2 && a.length === 1;")
	probe_row(c"array", w, c"indexOf", c"[1,2,3].indexOf(2) === 1 && [1,2,1].lastIndexOf(1) === 2;")
	probe_row(c"array", w, c"concat", c"[1].concat([2],3).length === 3;")
	probe_row(c"array", w, c"some", c"[1,2].some(function(x){ return x > 1; });")
	probe_row(c"array", w, c"join", c"[1,2,3].join('-') === '1-2-3';")
	probe_row(c"array", w, c"Array constructor", c"Array(3).length === 3 && new Array(1, 2).length === 2 && Array.isArray(Array());")
	probe_row(c"array", w, c"shift/unshift", c"var a = [1, 2]; a.unshift(0); a.shift() === 0 && a.length === 2;")
	probe_row(c"array", w, c"map/filter", c"[1,2,3].map(function(x){ return x * 2; }).join() === '2,4,6' && [1,2,3].filter(function(x){ return x > 1; }).length === 2;")
	probe_row(c"array", w, c"every/forEach", c"var n = 0; [1,2].forEach(function(x){ n = n + x; }); n === 3 && [1,2].every(function(x){ return x > 0; });")
	probe_row(c"array", w, c"find/findIndex", c"[1,2,3].find(function(x){ return x > 1; }) === 2 && [1,2,3].findIndex(function(x){ return x > 1; }) === 1;")
	probe_row(c"array", w, c"reduce", c"[1,2,3].reduce(function(p, x){ return p + x; }) === 6 && [1,2,3].reduceRight(function(p, x){ return p + x; }, 0) === 6;")
	probe_row(c"array", w, c"slice generic", c"Array.prototype.slice.call({0:'a',1:'b',length:2}, 1)[0] === 'b';")
	probe_row(c"array", w, c"subclass species", c"class S extends Array {} var s = new S(); s.push(1, 2); s.map(function(x){ return x; }) instanceof S;")


void probe_string(char* w):
	probe_row(c"string", w, c"trim", c"'  a '.trim() === 'a';")
	probe_row(c"string", w, c"charAt/charCodeAt", c"'abc'.charAt(1) === 'b' && 'abc'.charCodeAt(1) === 98;")
	probe_row(c"string", w, c"substring", c"'abcdef'.substring(1,3) === 'bc';")
	probe_row(c"string", w, c"fromCharCode", c"String.fromCharCode(97,98) === 'ab';")
	probe_row(c"string", w, c"toUpperCase", c"'abc'.toUpperCase() === 'ABC' && 'ABC'.toLowerCase() === 'abc';")
	probe_row(c"string", w, c"trimStart/trimEnd", c"' a '.trimStart() === 'a ' && ' a '.trimEnd() === ' a' && String.prototype.trimLeft === String.prototype.trimStart;")
	probe_row(c"string", w, c"full case mapping", c"'Stra\\u00dfe'.toUpperCase() === 'STRASSE' && '\\u0391\\u03a3'.toLowerCase() === '\\u03b1\\u03c2';")
	probe_row(c"string", w, c"split/replace", c"'a,b'.split(',').length === 2 && 'abc'.replace('b', 'X') === 'aXc';")


void probe_numeric(char* w):
	probe_row(c"numeric", w, c"Math.pow", c"Math.pow(2,10) === 1024;")
	probe_row(c"numeric", w, c"parseInt", c"parseInt('42px') === 42 && parseInt('ff', 16) === 255;")
	probe_row(c"numeric", w, c"parseFloat", c"parseFloat('3.5e1x') === 35;")
	probe_row(c"numeric", w, c"Number constants", c"Number.MAX_VALUE > 1e308 && Number.MIN_VALUE > 0;")


void probe_function(char* w):
	probe_row(c"function", w, c"bind", c"function f(a,b){ return this.x + a + b; } f.bind({x:1}, 2)(3) === 6;")
	probe_row(c"function", w, c"Error cause", c"new Error('m', {cause: 5}).cause === 5;")
	probe_row(c"function", w, c"Error.isError", c"Error.isError(new Error('x')) && !Error.isError({});")
	probe_row(c"function", w, c"call/apply", c"function f(a){ return this.x + a; } f.call({x:1}, 2) === 3 && f.apply({x:1}, [2]) === 3;")


void probe_promise(char* w):
	probe_row(c"promise", w, c"Promise.all", c"typeof Promise.all === 'function' && typeof Promise.allSettled === 'function';")
	probe_row(c"promise", w, c"Promise.race", c"typeof Promise.race === 'function';")
	probe_row(c"promise", w, c"finally", c"typeof Promise.prototype.finally === 'function';")


void probe_evaluator(char* w):
	probe_row(c"evaluator", w, c"% Number", c"7 % 3 === 1 && -7 % 3 === -1;")
	probe_row(c"evaluator", w, c"% BigInt", c"7n % 3n === 1n;")
	probe_row(c"evaluator", w, c"+ coercion", c"1 + '2' === '12' && ({valueOf: function(){ return 3; }}) + 1 === 4;")
	probe_row(c"evaluator", w, c"arguments", c"function f(){ return arguments.length; } f(1,2,3) === 3;")
	probe_row(c"evaluator", w, c"mapped arguments", c"function f(a){ arguments[0] = 9; return a; } f(1) === 9;")


int main(int argc, int argv):
	char* want = c"all"
	int strict = 0
	args_init(argc, argv)
	for i in range(1, argc):
		char* arg = args_get(i)
		if (strcmp(arg, c"--strict") == 0): strict = 1
		else: want = arg
	probe_object(want)
	probe_array(want)
	probe_string(want)
	probe_numeric(want)
	probe_function(want)
	probe_promise(want)
	probe_evaluator(want)
	print(c"failures: ")
	println(itoa(probe_failures))
	if (strict && probe_failures > 0): return 1
	return 0
