# wbuild: name=javascript_runtime_objects_test
# wbuild: target=javascript_runtime_objects_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_objects_test.w -o bin/javascript_runtime_objects_test"
# wbuild: step="bin/javascript_runtime_objects_test" expect_stdout="javascript_runtime_objects_test: OK"
# wbuild: step="bin/javascript_runtime_objects_test memory" expect_stdout="javascript_runtime_objects_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime


struct object_fixture:
	js_value* receiver
	js_value* value
	int reads
	int writes


js_value* object_get(void* runtime, void* context, js_value* receiver, js_text* key):
	js_runtime* rt = cast(js_runtime*, runtime)
	object_fixture* fixture = cast(object_fixture*, context)
	assert1(receiver == fixture.receiver)
	assert_equal(-1, js_runtime_collect(rt))
	assert1(js_runtime_eval(rt, c"1;", 2, 10) == 0)
	if (js_runtime_key_is(key, c"live") == 0): return 0
	fixture.reads = fixture.reads + 1
	return fixture.value


int object_set(void* runtime, void* context, js_value* receiver, js_text* key, js_value* value):
	js_runtime* rt = cast(js_runtime*, runtime)
	object_fixture* fixture = cast(object_fixture*, context)
	assert1(receiver == fixture.receiver)
	assert_equal(-1, js_runtime_collect(rt))
	if (js_runtime_key_is(key, c"live") == 0): return 0
	fixture.writes = fixture.writes + 1
	js_runtime_unroot(rt, fixture.value)
	fixture.value = value
	js_runtime_root(rt, value)
	return 1


js_value* object_method(void* runtime, void* context, js_value* receiver, list[js_value*] arguments):
	js_runtime* rt = cast(js_runtime*, runtime)
	assert1(receiver == cast(js_value*, context))
	if (arguments.length > 0): js_runtime_set(rt, receiver, c"stored", arguments[0])
	return receiver


js_value* objects_eval(js_runtime* rt, char* source):
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	assert_equal(0, result.status)
	return result.value


void test_objects():
	js_runtime* rt = js_runtime_new()
	js_runtime* other = js_runtime_new()
	js_value* parent = js_runtime_alloc(rt, 5)
	js_value* child = js_runtime_alloc(rt, 5)
	assert1(js_runtime_root(rt, child))
	assert1(js_runtime_set_prototype(rt, child, parent))
	assert_equal(0, js_runtime_set_prototype(rt, parent, child))
	assert_equal(0, js_runtime_set_prototype(rt, parent, other.global))
	assert1(js_runtime_set(rt, rt.global, c"child", child))
	js_text* key = js_runtime_key(c"fixed")
	js_value* seven = js_runtime_number(rt, 7.0)
	assert1(js_runtime_define_data(rt, parent, key, seven, 0, 1, 0))
	assert1(js_runtime_get(rt, child, c"fixed") == seven)
	assert_equal(0, js_runtime_set(rt, child, c"fixed", rt.undefined_value))
	assert_equal(0, js_runtime_define_data(rt, parent, key, rt.undefined_value, 0, 1, 0))
	assert1(js_runtime_define_data(rt, parent, key, seven, 0, 1, 0))
	assert_equal(0, js_runtime_delete(rt, parent, key))
	js_text_free(key)
	assert1(js_runtime_set(rt, parent, c"shadow", seven))
	assert1(js_runtime_set(rt, child, c"shadow", rt.undefined_value))
	assert1(js_runtime_get(rt, parent, c"shadow") == seven)
	assert1(js_runtime_get(rt, child, c"shadow") == rt.undefined_value)
	js_value* getter = objects_eval(rt, c"(function() { return this.shadow; });")
	js_value* setter = objects_eval(rt, c"(function(value) { this.shadow = value; });")
	key = js_runtime_key(c"access")
	assert1(js_runtime_define_accessor(rt, parent, key, getter, setter, 1, 1))
	js_text_free(key)
	objects_eval(rt, c"child.access = 42;")
	assert1(objects_eval(rt, c"child.access;").number == 42.0)
	# Getter and setter functions, their closures, and the prototype survive
	# solely through the child's graph; host contexts need their own roots.
	js_runtime_collect(rt)
	assert1(objects_eval(rt, c"child.access;").number == 42.0)
	js_value* method = js_runtime_host_callable(rt, child, object_method)
	assert1(js_runtime_set(rt, parent, c"method", method))
	assert1(objects_eval(rt, c"child.method(12);") == child)
	assert1(js_runtime_get(rt, child, c"stored").number == 12.0)
	list[js_value*] arguments = new list[js_value*]
	assert1(js_runtime_invoke_receiver(rt, method, child, arguments, 100).value == child)
	assert_equal(2, js_runtime_invoke_receiver(rt, method, other.undefined_value, arguments, 100).status)
	__w_list_free(cast(__w_list*, arguments))
	objects_eval(rt, c"0;")
	object_fixture fixture
	fixture.receiver = child
	fixture.value = seven
	fixture.reads = 0
	fixture.writes = 0
	js_runtime_root(rt, seven)
	assert1(js_runtime_set_host_hooks(rt, parent, &fixture, object_get, object_set))
	assert1(objects_eval(rt, c"child.live = 23; child.live;").number == 23.0)
	assert_equal(1, fixture.reads)
	assert_equal(1, fixture.writes)
	assert1(js_runtime_get(rt, child, c"live").number == 23.0)
	assert_equal(0, rt.running)
	assert_equal(0, rt.depth)
	js_runtime_collect(rt)
	assert1(js_runtime_get(rt, child, c"live").number == 23.0)
	assert1(js_runtime_set_host_hooks(rt, parent, 0, 0, 0))
	js_runtime_unroot(rt, fixture.value)
	js_runtime_free(other)
	js_runtime_free(rt)


js_value* recursive_get(void* runtime, void* context, js_value* receiver, js_text* key):
	js_runtime* rt = cast(js_runtime*, runtime)
	return js_runtime_member_read(rt, receiver, key)


void test_object_limits():
	js_runtime* rt = js_runtime_new()
	js_value* object = js_runtime_alloc(rt, 5)
	js_runtime_root(rt, object)
	assert1(js_runtime_set_host_hooks(rt, object, 0, recursive_get, 0))
	rt.max_depth = 8
	js_runtime_get(rt, object, c"recursive")
	assert_equal(5, rt.completion.status)
	assert_equal(0, rt.running)
	assert_equal(0, rt.depth)
	assert1(js_runtime_collect(rt) >= 0)
	js_runtime_set_host_hooks(rt, object, 0, 0, 0)
	objects_eval(rt, c"0;")
	rt.max_properties = 1
	js_text* key = js_runtime_key(c"x")
	assert1(js_runtime_define_data(rt, object, key, rt.undefined_value, 1, 1, 1))
	js_text_free(key)
	key = js_runtime_key(c"y")
	assert_equal(0, js_runtime_define_accessor(rt, object, key, 0, 0, 1, 1))
	assert_equal(5, rt.completion.status)
	js_text_free(key)
	js_runtime_free(rt)


void test_completion_errors():
	js_runtime* rt = js_runtime_new()
	assert1(objects_eval(rt, c"1; let empty;").number == 1.0)
	assert1(objects_eval(rt, c"2; {}; function named(a, b) {};").number == 2.0)
	assert1(objects_eval(rt, c"let i = 0; while (i++ < 2) { i; }").number == 2.0)
	assert1(objects_eval(rt, c"while (true) { 8; break; }").number == 8.0)
	assert1(objects_eval(rt, c"3; if (false) 4;") == rt.undefined_value)
	assert1(objects_eval(rt, c"named.length;").number == 2.0)
	assert1(js_runtime_key_is(objects_eval(rt, c"named.name;").text, c"named"))
	assert1(js_runtime_key_is(objects_eval(rt, c"try { missing; } catch (e) { e.name; }").text, c"ReferenceError"))
	assert1(js_runtime_key_is(objects_eval(rt, c"try { null.x; } catch (e) { e.name; }").text, c"TypeError"))
	assert1(objects_eval(rt, c"true.foo;") == rt.undefined_value)
	js_runtime_free(rt)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	test_objects()
	test_object_limits()
	test_completion_errors()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_objects_test: OK")
	return 0
