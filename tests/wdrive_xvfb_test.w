# wbuild: target=wdrive_xvfb_test tag=tests_x64 dep=wv2 dep=wdrive dep=wdrive_fixture
# wbuild: step="bin/wv2 x64 tests/wdrive_xvfb_test.w -o bin/wdrive_xvfb_test"
# wbuild: step="bin/wdrive_xvfb_test" expect_stdout="wdrive xvfb" timeout=180000
/*
End-to-end check of graphics.control + tools/wdrive.w on a real X
server (docs/projects/wdrive.md): bin/wdrive starts its own Xvfb, runs
bin/wdrive_fixture (tests/wdrive_fixture.w, a plain graphics.ui program
with no knowledge of the channel) and a script that reads the
accessibility tree, clicks the "Paint" button by its a11y node, types
into the textbox, and asserts pixels, a11y values and screenshots.
Then the same through `wdrive serve` on stdin, and failure exits.

Prints "wdrive xvfb OK" on success. Without Xvfb or libGL it prints a
SKIP line (lib/ci_skip.w: a failure under W_CI_NO_SKIP); the build
greps for the "wdrive xvfb" prefix, the graphics_gl_texture_test
convention.
*/
import lib.lib
import lib.ci_skip
import tools.host_tools
import graphics.image.png


int checks_failed


void check(int ok, char* what):
	if (ok): return
	print_error(c"wdrive_xvfb_test: FAILED: ")
	print_error(what)
	print_error(c"\n")
	checks_failed = checks_failed + 1


int has_libgl():
	if (process_path_readable(c"/usr/lib/x86_64-linux-gnu/libGL.so.1")): return 1
	if (process_path_readable(c"/usr/lib64/libGL.so.1")): return 1
	if (process_path_readable(c"/usr/lib/libGL.so.1")): return 1
	return 0


# The NDJSON line of step index in out, or 0.
json_value* step_line(char* out, int index):
	list[char*] lines = ht_split(out, '\n')
	for char* line in lines:
		if (line[0] != '{'): continue
		json_value* v = json_parse(line)
		if ((v != 0) && (ht_number(v, c"step") == index)): return v
	return 0


int step_ok(char* out, int index):
	json_value* v = step_line(out, index)
	if (v == 0): return 0
	json_value* ok = json_object_get(v, c"ok")
	return (ok != 0) && (ok.int_value == 1)


int png_size_is(char* path, int w, int h):
	string_builder* bytes = ht_read(path)
	wresult[rgba_image*]* result = png_decode_n(bytes.data, bytes.length, 0)
	if (result.ok == 0): return 0
	rgba_image* image = result.value
	return (image.width == w) && (image.height == h)


int main(int argc, int argv):
	if (process_which(c"Xvfb") == 0):
		test_skip(c"wdrive xvfb SKIP: Xvfb is not installed")
		return 0
	if (has_libgl() == 0):
		test_skip(c"wdrive xvfb SKIP: no libGL.so.1")
		return 0
	char* dir = ht_temp()
	char* steps = c"[{\"cmd\":\"step\",\"frames\":2},{\"cmd\":\"assert_pixel\",\"x\":310,\"y\":230,\"rgba\":[245,245,245],\"tolerance\":3},{\"cmd\":\"screenshot\",\"path\":\"before.png\"},{\"cmd\":\"assert_a11y\",\"role\":\"text\",\"name\":\"clicks: 0\"},{\"cmd\":\"click_node\",\"role\":\"button\",\"name\":\"Paint\"},{\"cmd\":\"step\",\"frames\":2},{\"cmd\":\"assert_pixel\",\"x\":310,\"y\":230,\"rgba\":[23,23,23],\"tolerance\":3},{\"cmd\":\"assert_a11y\",\"role\":\"text\",\"name\":\"clicks: 1\"},{\"cmd\":\"click_node\",\"role\":\"textbox\"},{\"cmd\":\"text\",\"text\":\"hello\"},{\"cmd\":\"key\",\"name\":\"Backspace\"},{\"cmd\":\"assert_a11y\",\"role\":\"textbox\",\"value\":\"hell\",\"focused\":true},{\"cmd\":\"screenshot\",\"path\":\"after.png\"}]"
	process_result* r = ht_run(ht_argv(c"bin/wdrive", c"run", c"--xvfb", c"--out", dir, c"--steps", steps, c"--", c"bin/wdrive_fixture"), 0, 0, 120000)
	char* out = r.stdout_text
	check(r.status == 0, c"wdrive run exits 0")
	if (r.status != 0):
		print_error(out)
		print_error(r.stderr_text)
	for i in range(14): check(step_ok(out, i), strjoin(c"run step ok: ", itoa(i)))
	json_value* hello = step_line(out, 0)
	check((hello != 0) && (strcmp(ht_text(hello, c"backend"), c"x11") == 0), c"hello names the x11 backend")
	check(ht_contains(r.stderr_text, c"fixture clicks 1"), c"program stdout is forwarded to stderr")
	check(png_size_is(path_join(dir, c"before.png"), 320, 240), c"before.png is a 320x240 PNG")
	check(png_size_is(path_join(dir, c"after.png"), 320, 240), c"after.png is a 320x240 PNG")

	# serve: steps on stdin, a failing step answers ok:false and the
	# session goes on; --size resizes before the handshake.
	char* input = c"{\"id\":7,\"cmd\":\"pixel\",\"x\":1,\"y\":1}\n{\"cmd\":\"assert_pixel\",\"x\":1,\"y\":1,\"rgba\":\"#000000\"}\n{\"cmd\":\"a11y_tree\"}\n{\"cmd\":\"close\"}\n"
	process_result* s = ht_run(ht_argv(c"bin/wdrive", c"serve", c"--xvfb", c"--size", c"400x300", c"--", c"bin/wdrive_fixture"), 0, input, 120000)
	check(s.status == 0, c"wdrive serve exits 0")
	json_value* served = step_line(s.stdout_text, 0)
	check((served != 0) && (ht_number(served, c"width") == 400) && (ht_number(served, c"height") == 300), c"--size resized the window")
	json_value* first = step_line(s.stdout_text, 1)
	check((first != 0) && (ht_number(first, c"id") == 7), c"serve echoes the step id")
	check(step_ok(s.stdout_text, 1), c"serve pixel ok")
	check(step_ok(s.stdout_text, 2) == 0, c"serve assert_pixel mismatch is ok:false")
	check(ht_contains(s.stdout_text, c"\"error\":\"pixel mismatch\""), c"mismatch is reported")
	check(step_ok(s.stdout_text, 3), c"serve a11y_tree ok")
	check(step_ok(s.stdout_text, 4), c"serve close ok")

	# A failing run step exits 1; a program that never connects exits 3.
	process_result* f = ht_run(ht_argv(c"bin/wdrive", c"run", c"--xvfb", c"--steps", c"[{\"cmd\":\"assert_a11y\",\"name\":\"no such node\"}]", c"--", c"bin/wdrive_fixture"), 0, 0, 120000)
	check(f.status == 1, c"a failed step exits 1")
	process_result* n = ht_run(ht_argv(c"bin/wdrive", c"run", c"--xvfb", c"--timeout-ms", c"3000", c"--", c"true"), 0, 0, 120000)
	check(n.status == 3, c"a program that never connects exits 3")
	ht_cleanup()
	if (checks_failed > 0): return 1
	println(c"wdrive xvfb OK")
	return 0
