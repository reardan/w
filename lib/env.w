/*
Environment variable access.

lib/lib.w's _main captures the address of the kernel-provided environment
vector (envp) in environ_ptr before calling main(). The vector is a
NULL-terminated array of word-sized char* entries, each pointing at a
"NAME=value" string. These helpers read that vector and build modified
copies for passing to execve; nothing here mutates the parent's
environment.
*/
import lib.lib


# The raw envp for pass-through to execve. NULL-terminated char* vector.
char** env_current():
	return cast(char**, environ_ptr)


char* env_entry_at(char** envp, int i):
	char** entry = cast(char**, cast(int, envp) + i * __word_size__)
	return *entry


int env_vector_count(char** envp):
	if (envp == 0):
		return 0
	int count = 0
	while (env_entry_at(envp, count) != 0):
		count = count + 1
	return count


int env_count():
	return env_vector_count(env_current())


# The i-th "NAME=value" entry, or 0 when out of range.
char* env_at(int i):
	if ((i < 0) | (i >= env_count())):
		return 0
	return env_entry_at(env_current(), i)


# When entry starts with "name=", returns the index of the character after
# '='; otherwise returns -1.
int env_match_name(char* entry, char* name):
	int i = 0
	while (name[i] != 0):
		if (entry[i] != name[i]):
			return -1
		i = i + 1
	if (entry[i] != '='):
		return -1
	return i + 1


# Value of name in the current environment (pointer into the entry, do not
# free), or 0 when unset.
char* env_get(char* name):
	char** envp = env_current()
	if (envp == 0):
		return 0
	int i = 0
	char* entry = env_entry_at(envp, i)
	while (entry != 0):
		int value_index = env_match_name(entry, name)
		if (value_index >= 0):
			return entry + value_index
		i = i + 1
		entry = env_entry_at(envp, i)
	return 0


# Malloc'd "name=value" string.
char* env_make_entry(char* name, char* value):
	int size = strlen(name) + strlen(value) + 2
	char* entry = malloc(size)
	char* cur = strcpy(entry, name)
	cur[0] = '='
	strcpy(cur + 1, value)
	return entry


# Malloc'd NULL-terminated copy of base with name set to value: an existing
# "name=" entry is replaced, otherwise the new entry is appended. base may
# be 0 (treated as empty). The vector and the new entry are malloc'd; the
# other entries are shared with base. Suitable as an execve envp.
char** env_copy_with(char** base, char* name, char* value):
	int count = env_vector_count(base)
	# Room for every base entry plus a possible append plus the NULL.
	char* vector = malloc((count + 2) * __word_size__)
	char* new_entry = env_make_entry(name, value)
	int replaced = 0
	int out = 0
	int i = 0
	while (i < count):
		char* entry = env_entry_at(base, i)
		if (env_match_name(entry, name) >= 0):
			save_word(vector + out * __word_size__, cast(int, new_entry))
			replaced = 1
		else:
			save_word(vector + out * __word_size__, cast(int, entry))
		out = out + 1
		i = i + 1
	if (replaced == 0):
		save_word(vector + out * __word_size__, cast(int, new_entry))
		out = out + 1
	save_word(vector + out * __word_size__, 0)
	return cast(char**, vector)
