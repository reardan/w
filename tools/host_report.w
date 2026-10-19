# JSON evidence and monotonic measurement helpers for host utilities.
import tools.host_metrics

void vj_s(json_value* obj, char* key, char* value): json_object_set(obj, key, json_string(value))
void vj_i(json_value* obj, char* key, int value): json_object_set(obj, key, json_int(value))
void vj_f(json_value* obj, char* key, float value): json_object_set(obj, key, json_float(value))
void vj_b(json_value* obj, char* key, int value): json_object_set(obj, key, json_bool(value))
json_value* vj_one(char* key, char* value):
	json_value* obj = json_object()
	vj_s(obj, key, value)
	return obj
json_value* vj_copy(json_value* value): return json_parse(json_stringify(value))
json_value* vj_strings(list[char*] values):
	json_value* array = json_array()
	for char* value in values: json_array_push(array, json_string(value))
	return array
void vj_write(char* path, json_value* value):
	ht_mkdir(path_dirname(path))
	char* text = strjoin(json_stringify(value), c"\n")
	ht_write(path, text, strlen(text))
int vm_ns():
	ht_require(__word_size__ == 8, c"native VM evidence requires a 64-bit host build")
	timespec now
	ht_require(clock_gettime(1, cast(int*, &now)) == 0, c"monotonic clock unavailable")
	return now.seconds * 1000000000 + now.nanoseconds
char* vm_command(char* command): return strip(ht_checked(ht_command(command)).stdout_text)
