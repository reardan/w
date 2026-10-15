# wbuild: name=javascript_browser_language_test
# wbuild: target=javascript_browser_language_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/browser_language_test.w -o bin/javascript_browser_language_test"
# wbuild: step="bin/javascript_browser_language_test" expect_stdout="javascript_browser_language_test: OK"
import lib.assert
import libs.extras.javascript.runtime

void browser_language_number(char* source, float64 expected):
	js_runtime* rt = js_runtime_new()
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	if (result.status != 0):
		println(source)
		println(result.message)
	assert_equal(0, result.status)
	assert1(result.value.number == expected)
	js_runtime_free(rt)

int main():
	browser_language_number(c"function f({x, y = 3} = {}, ...rest) { return x + y + rest[0]; } f({x:2}, 7);", 12.0)
	browser_language_number(c"const [a, , b = 4, ...rest] = [1,2,undefined,8,9]; a + b + rest[1];", 14.0)
	browser_language_number(c"const {a:x, b = 3, ...rest} = {a:2, c:7}; x + b + rest.c;", 12.0)
	browser_language_number(c"const f = ({x=2}, y=3) => x+y; f({});", 5.0)
	browser_language_number(c"let n=0; for (const [a,b] of [[1,2],[3,4]]) n += a+b; n;", 10.0)
	browser_language_number(c"const a=[1,...[2,3],4]; const o={x:1,...{x:3,y:5},z:2}; a[3]+o.x+o.y+o.z;", 14.0)
	browser_language_number(c"function sum(a,b,c){return a+b+c;} sum(1,...[2,3]);", 6.0)
	browser_language_number(c"const o={x:8, f(n=2){return this.x+n;}}; o.f();", 10.0)
	browser_language_number(c"let n=0; const a=null; const b=a?.[n++].f(n++); (b ?? 4)+n;", 4.0)
	browser_language_number(c"const o={x:8, f(n){return this.x+n;}}; o?.f(2)+o.f?.(3);", 21.0)
	browser_language_number(c"let caught=0; try {(null?.x).y;} catch {caught=1;} caught;", 1.0)
	browser_language_number(c"let caught=0; function f(a=b,b=2){} try {f();}catch {caught=1;} caught;", 1.0)
	browser_language_number(c"let n=0; n |= 1 << 3; n &= ~(1 << 2); n;", 8.0)
	browser_language_number(c"(-1 >>> 0) + (0xffffffff >> 31) + (0x80000000 << 1);", 4294967294.0)
	browser_language_number(c"(1e100 | 0) + (NaN | 0) + (Infinity | 0) + (0b101 ^ 0o3);", 6.0)
	browser_language_number(c"const a=[1]; a.push(2,3); const x=a.shift(); const b=a.slice(-1); a.splice(0,1,7,8); x+b[0]+a[1]+a.length;", 15.0)
	browser_language_number(c"const a=[1,2]; a.length=0; a.push(7); a.length+(a.includes(7)?10:0);", 11.0)
	browser_language_number(c"const s='a😀z'; s.codePointAt(1);", 128512.0)
	browser_language_number(c"('hello'.startsWith('ell',1)?10:0)+'hello'.indexOf('l',3)+'hello'.slice(-2).length;", 15.0)
	browser_language_number(c"const o={x:9,f(){return this.x;}}; (o?.f)();", 9.0)
	browser_language_number(c"const a=[1,2,3]; a.length=1; const b=a.slice(); b.length + (b[1]===undefined?10:0);", 11.0)
	println(c"javascript_browser_language_test: OK")
	return 0
