import lib.testing
import tools.wexec


void test_wexec_rejected_sandbox_preserves_atomic_staging():
	json_value* step = json_object()
	json_object_set(step, c"sandbox", json_string(c"cell"))
	char* output = c"bin/wexec_cell_stage_guard"
	json_value* args = json_array()
	json_array_push(args, json_string(c"/bin/false"))
	json_array_push(args, json_string(output))
	json_object_set(step, c"cmd", args)
	json_object_set(step, c"atomic_output", json_string(output))
	string_builder* path = string_from(output)
	string_append(path, c".stage.")
	string_append_int(path, getpid())
	string_append(path, c".0")
	file_write_text(path.data, c"preserve rejected step staging")
	assert_equal(1, wexec_run_step(c"cell-stage-rejection", 0, step))
	char* text = file_read_text(path.data)
	asserts(c"rejected sandbox never stages host output", text != 0)
	assert_strings_equal(c"preserve rejected step staging", text)
	free(text)
	unlink(path.data)
	string_free(path)
	json_free(step)


