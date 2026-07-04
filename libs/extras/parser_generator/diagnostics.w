/*
Structured diagnostics for generated lexers and parsers.
*/
import lib.lib
import structures.array_list


struct pg_diagnostic:
	char* filename
	int line
	int column
	char* message
	char* expected
	char* found


struct pg_diagnostics:
	array_list* items


pg_diagnostics* pg_diagnostics_new():
	pg_diagnostics* diagnostics = new pg_diagnostics()
	diagnostics.items = array_list_new()
	return diagnostics


pg_diagnostic* pg_diagnostic_new(char* filename, int line, int column, char* message, char* expected, char* found):
	pg_diagnostic* diagnostic = new pg_diagnostic()
	diagnostic.filename = filename
	diagnostic.line = line
	diagnostic.column = column
	diagnostic.message = strclone(message)
	diagnostic.expected = strclone(expected)
	diagnostic.found = strclone(found)
	return diagnostic


void pg_diagnostics_add(pg_diagnostics* diagnostics, char* filename, int line, int column, char* message, char* expected, char* found):
	if (diagnostics == 0):
		return
	array_list_push(diagnostics.items, pg_diagnostic_new(filename, line, column, message, expected, found))


int pg_diagnostics_count(pg_diagnostics* diagnostics):
	if (diagnostics == 0):
		return 0
	return diagnostics.items.length


pg_diagnostic* pg_diagnostics_get(pg_diagnostics* diagnostics, int index):
	return array_list_get(diagnostics.items, index)


void pg_diagnostic_print(pg_diagnostic* diagnostic):
	print2(diagnostic.filename)
	print2(c":")
	print2(itoa(diagnostic.line))
	print2(c":")
	print2(itoa(diagnostic.column))
	print2(c": ")
	print2(diagnostic.message)
	if (strlen(diagnostic.expected) > 0):
		print2(c": expected ")
		print2(diagnostic.expected)
	if (strlen(diagnostic.found) > 0):
		print2(c", found ")
		print2(diagnostic.found)
	println2(c"")


void pg_diagnostics_print(pg_diagnostics* diagnostics):
	if (diagnostics == 0):
		return
	int i = 0
	while (i < diagnostics.items.length):
		pg_diagnostic_print(array_list_get(diagnostics.items, i))
		i = i + 1


void pg_diagnostic_free(pg_diagnostic* diagnostic):
	if (diagnostic == 0):
		return
	free(diagnostic.message)
	free(diagnostic.expected)
	free(diagnostic.found)
	free(diagnostic)


void pg_diagnostics_free(pg_diagnostics* diagnostics):
	if (diagnostics == 0):
		return
	int i = 0
	while (i < diagnostics.items.length):
		pg_diagnostic_free(array_list_get(diagnostics.items, i))
		i = i + 1
	array_list_free(diagnostics.items)
	free(diagnostics)
