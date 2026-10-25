# wbuild: binary=wmermaid
import lib.args
import libs.extras.mermaid.io
import libs.extras.mermaid.render
import libs.extras.mermaid.serialize
import libs.extras.mermaid.source
import lib.bytes

int wm_number(char* text):
	if (text == 0 || text[0] == 0): return -1
	int value = 0
	int i = 0
	while (text[i] != 0):
		if (text[i] < '0' || text[i] > '9'): return -1
		value = value * 10 + text[i] - '0'
		if (value > MM_MAX_SOURCE): return -1
		i = i + 1
	return value

int main(int argc, int argv):
	args_init(argc, argv)
	int selected = 0
	if (argc >= 5 && strcmp(args_get(argc - 2), c"--diagram") == 0):
		selected = wm_number(args_get(argc - 1))
		if (selected < 0):
			println2(c"wmermaid: invalid diagram index")
			return 2
		argc = argc - 2
	if (argc < 3):
		println2(c"usage: wmermaid check|read INPUT | write|svg|canonical INPUT OUTPUT | format [--check] INPUT [-o OUTPUT] | edit INPUT START END REPLACEMENT_FILE OUTPUT [--diagram ZERO_BASED_INDEX]")
		return 2
	char* command = args_get(1)
	# format [--check] INPUT [-o OUTPUT]: canonical source to stdout or OUTPUT;
	# --check only reports (exit 1) when INPUT differs from its canonical form.
	int format = strcmp(command, c"format") == 0
	int format_check = 0
	char* format_output = 0
	int input_index = 2
	if (format):
		if (argc >= 4 && strcmp(args_get(2), c"--check") == 0):
			format_check = 1
			input_index = 3
		if (argc == input_index + 3 && format_check == 0 && strcmp(args_get(input_index + 1), c"-o") == 0):
			format_output = args_get(input_index + 2)
		else if (argc != input_index + 1):
			println2(c"wmermaid: invalid command or argument count")
			return 2
	int read = strcmp(command, c"read") == 0
	int check = strcmp(command, c"check") == 0
	int write = strcmp(command, c"write") == 0
	int canonical = strcmp(command, c"canonical") == 0
	int svg = strcmp(command, c"svg") == 0
	int edit = strcmp(command, c"edit") == 0
	if ((read == 0 && check == 0 && write == 0 && svg == 0 && canonical == 0 && edit == 0 && format == 0) || ((read || check) && argc != 3) || ((write || svg || canonical) && argc != 4) || (edit && argc != 7)):
		println2(c"wmermaid: invalid command or argument count")
		return 2
	mm_document* d = mm_read_selected(args_get(input_index), selected)
	if (d == 0):
		println2(c"wmermaid: cannot read input (I/O failure or 1 MiB limit)")
		return 1
	int status = 0
	int reported = 0
	if (read):
		io_result result
		status = io_write_all(1, d.source, d.length, &result) != IO_OK
	else if (write):
		io_result result
		status = mm_save(d, args_get(3), &result) != IO_OK
	else if (edit):
		mm_document* replacement = mm_read(args_get(5))
		mm_document* edited = 0
		if (replacement != 0): edited = mm_edit(d, wm_number(args_get(3)), wm_number(args_get(4)), replacement.source, replacement.length)
		if (edited == 0):
			println2(c"wmermaid: invalid edit range or unreadable replacement")
			status = 1
		else:
			io_result result
			status = mm_save(edited, args_get(6), &result) != IO_OK
		mm_document_free(edited)
		mm_document_free(replacement)
	else if (d.error != 0):
		char* message = mm_diagnostic(d)
		println2(message)
		free(message)
		status = 1
	else if (canonical || format):
		char* diff = 0
		char* source = mm_serialize_explain(d, &diff)
		if (source == 0):
			print2(c"wmermaid: no canonical form for this model")
			if (diff != 0):
				print2(c": ")
				print2(diff)
				free(diff)
			println2(c"")
			reported = 1
			status = 1
		else if (format_check):
			char* path = args_get(input_index)
			# Compare with the selected diagram's own text (inside its Markdown
			# fence, frontmatter included).
			mm_document* fence = mm_document_new()
			free(fence.source)
			fence.source = str_copy_range(d.source, 0, d.length)
			fence.length = d.length
			fence.source_end = d.length
			mm_source_fence_selected(fence, selected)
			int size = fence.source_end - fence.source_start
			int same = size == strlen(source) && bytes_equal(fence.source + fence.source_start, size, source, size)
			mm_document_free(fence)
			if (same == 0):
				print2(path)
				println2(c": not canonically formatted")
				reported = 1
				status = 1
			free(source)
		else if (format && format_output == 0):
			io_result result
			status = io_write_all(1, source, strlen(source), &result) != IO_OK
			free(source)
		else:
			char* output = format_output
			if (output == 0): output = args_get(3)
			io_result result
			status = file_write_durable(output, source, strlen(source), &result) != IO_OK
			free(source)
	else if (svg):
		mm_scene* scene = mm_render(d)
		char* text = mm_svg(scene)
		io_result result
		status = file_write_durable(args_get(3), text, strlen(text), &result) != IO_OK
		free(text)
		mm_scene_free(scene)
	else: println(c"Mermaid OK")
	if (status != 0 && d.error == 0 && reported == 0): println2(c"wmermaid: operation failed")
	mm_document_free(d)
	return status
