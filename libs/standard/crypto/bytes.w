import lib.lib


struct bytes_result:
	char* data
	int length
	int ok
	char* error


bytes_result bytes_ok(char* data, int length):
	bytes_result result
	result.data = data
	result.length = length
	result.ok = 1
	result.error = 0
	return result


bytes_result bytes_error(char* error):
	bytes_result result
	result.data = 0
	result.length = 0
	result.ok = 0
	result.error = error
	return result


bytes_result bytes_alloc_ok(int length):
	char* data = malloc(length + 1)
	if (data == 0):
		return bytes_error(c"allocation failed")
	data[length] = 0
	return bytes_ok(data, length)


void bytes_result_free(bytes_result result):
	if (result.data != 0):
		free(result.data)
