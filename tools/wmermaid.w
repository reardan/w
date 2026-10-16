# wbuild: binary=wmermaid
# wbuild: target=mermaid_cli_test tag=tests dep=wmermaid
# wbuild: step="python3 tools/mermaid_cli_test.py"
import lib.args
import libs.extras.mermaid.io
import libs.extras.mermaid.render

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
	if (argc < 3):
		println2(c"usage: wmermaid check|read INPUT | write|svg INPUT OUTPUT | edit INPUT START END REPLACEMENT_FILE OUTPUT")
		return 2
	char* command = args_get(1)
	int read = strcmp(command, c"read") == 0
	int check = strcmp(command, c"check") == 0
	int write = strcmp(command, c"write") == 0
	int svg = strcmp(command, c"svg") == 0
	int edit = strcmp(command, c"edit") == 0
	if ((read == 0 && check == 0 && write == 0 && svg == 0 && edit == 0) || ((read || check) && argc != 3) || ((write || svg) && argc != 4) || (edit && argc != 7)):
		println2(c"wmermaid: invalid command or argument count")
		return 2
	mm_document* d = mm_read(args_get(2))
	if (d == 0):
		println2(c"wmermaid: cannot read input (I/O failure or 1 MiB limit)")
		return 1
	int status = 0
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
	else if (svg):
		mm_scene* scene = mm_render(d)
		char* text = mm_svg(scene)
		io_result result
		status = file_write_durable(args_get(3), text, strlen(text), &result) != IO_OK
		free(text)
		mm_scene_free(scene)
	else: println(c"Mermaid OK")
	if (status != 0 && d.error == 0): println2(c"wmermaid: operation failed")
	mm_document_free(d)
	return status
