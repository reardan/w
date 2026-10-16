# wbuild: x64
# Explicit event consumer; this is not automatic compiler instrumentation.
import lib.assert
import structures.json
import libs.wgrind.heap
import libs.wgrind.report
import libs.wgrind.values


int capture_report(wg_context* c, char* buffer):
	int[2] fds
	assert_equal(0, pipe(&fds[0]))
	int reader = load_int32(cast(char*, &fds[0]))
	int writer = load_int32(cast(char*, &fds[0]) + 4)
	assert1(wg_report(c, writer))
	assert_equal(0, close(writer))
	int n = read(reader, buffer, 511)
	assert1(n >= 0)
	buffer[n] = 0
	assert_equal(0, close(reader))
	return n


void check_report_format():
	wg_context* c = wg_create(8, 8, 4)
	assert1(c != 0)
	assert_equal(0, c.error)
	char[512] buffer
	char[512] again
	assert_equal(0, capture_report(c, &buffer[0]))
	int minimum = 1 << (__word_size__ * 8 - 1)
	for kind in range(1, 7):
		wg_error(c, kind, -1, minimum - 1, 123, 456)
		c.error_allocation = 789
		c.error_free = 999
		c.error_offset = minimum
		assert1(capture_report(c, &buffer[0]) > 0)
		assert1(capture_report(c, &again[0]) > 0)
		assert_strings_equal(&buffer[0], &again[0])
		json_value* report = json_parse(&buffer[0])
		assert1(report != 0)
		assert_strings_equal(wg_error_name(kind), json_object_get(report, c"kind").string_value)
		assert_equal(kind, json_object_get(report, c"code").int_value)
		assert_equal(minimum - 1, json_object_get(report, c"size").int_value)
		assert_equal(minimum, json_object_get(report, c"offset").int_value)
		char* address = json_object_get(report, c"address").string_value
		assert_equal(__word_size__ * 2 + 2, strlen(address))
		assert_equal('0', address[0])
		assert_equal('x', address[1])
		for i in range(2, __word_size__ * 2 + 2): assert_equal('f', address[i])
		assert_equal(0, wg_report(c, -1)) # failed output is never success
		json_free(report)
		wg_clear_error(c)
	wg_error(c, WG_INCOMPLETE, 0, 0, 0, 0)
	assert1(capture_report(c, &buffer[0]) > 0)
	json_value* report = json_parse(&buffer[0])
	assert1(report != 0)
	assert_strings_equal(c"incomplete", json_object_get(report, c"kind").string_value)
	assert_equal(WG_INCOMPLETE, json_object_get(report, c"code").int_value)
	json_free(report)
	wg_clear_error(c)
	assert_equal(WG_INCOMPLETE, c.error)
	wg_destroy(c)


void check_native_allocation_events():
	wg_context* c = wg_create(8, 8, 4)
	assert1(c != 0)
	assert_equal(0, c.error)
	char* source = cast(char*, malloc(8))
	char* dest = cast(char*, malloc(8))
	assert1(source != 0)
	assert1(dest != 0)
	assert1(wg_allocate(c, cast(int, source), 8, 0, 111))
	assert1(wg_allocate(c, cast(int, dest), 8, 0, 222))
	wg_value value
	# The source is physically initialized but logically undefined. This
	# avoids actually reading an indeterminate host value in the test.
	source[0] = 42
	assert1(wg_load(c, cast(int, source), 1, 300, &value))
	value.value = source[0]
	assert1(wg_store(c, cast(int, dest), 1, 301, &value))
	dest[0] = value.value
	assert1(wg_load(c, cast(int, dest), 1, 302, &value))
	value.value = dest[0]
	assert_equal(0, wg_use(c, &value, 303))
	assert_equal(111, c.error_origin)
	char[512] buffer
	assert1(capture_report(c, &buffer[0]) > 0)
	json_value* report = json_parse(&buffer[0])
	assert1(report != 0)
	assert_strings_equal(c"undefined-value", json_object_get(report, c"kind").string_value)
	char* origin = json_object_get(report, c"origin").string_value
	assert_strings_equal(c"6f", origin + strlen(origin) - 2)
	json_free(report)
	wg_clear_error(c)
	wg_value zero
	wg_value_set(&zero, 0, 0, 0)
	assert1(wg_binary(c, WG_AND, 1, &value, &zero, &value))
	assert1(wg_use(c, &value, 304)) # masking eliminates undefined bits
	assert_equal(0, wg_load(c, cast(int, source) - 1, 1, 305, &value))
	assert_equal(WG_INVALID_READ, c.error)
	assert_equal(-1, c.error_offset)
	wg_clear_error(c)
	assert1(wg_deallocate(c, cast(int, source), 306))
	assert_equal(0, wg_load(c, cast(int, source), 1, 307, &value))
	assert_equal(111, c.error_allocation)
	assert_equal(306, c.error_free)
	wg_clear_error(c)
	assert1(wg_deallocate(c, cast(int, dest), 308))
	free(source)
	free(dest)
	wg_destroy(c)


int main():
	check_report_format()
	check_native_allocation_events()
	println(c"wgrind_report_test: OK")
	return 0
