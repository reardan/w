import lib.memory
import lib.lib


int main(int argc, char** argv):
	malloc_provenance_enabled = 1
	if (argc != 2): return 2
	char* mode = argv[1]
	if (strcmp(mode, c"record") == 0):
		malloc_provenance_record(cast(void*, 1), 8)
		return 0
	if (strcmp(mode, c"null") == 0):
		__w_foreign_owner_check(cast(void*, 0), 8, 0)
		return 0
	if (strcmp(mode, c"unknown") == 0):
		__w_foreign_owner_check(cast(void*, 4096), 8, 0)
		return 0
	if (strcmp(mode, c"sentinel") == 0):
		void* tombstone = malloc(8)
		free(tombstone)
		__w_foreign_owner_check(cast(void*, 1), 8, 0)
		return 0
	if (strcmp(mode, c"misaligned") == 0):
		__w_foreign_owner_check(cast(void*, 3), -8, 0)
		return 0
	char* value = cast(char*, malloc(8))
	if (strcmp(mode, c"interior") == 0): __w_foreign_owner_check(value + 1, 1, 0)
	if (strcmp(mode, c"undersized") == 0): __w_foreign_owner_check(value, 9, 0)
	if (strcmp(mode, c"freed") == 0):
		free(value)
		__w_foreign_owner_check(value, 8, 0)
	return 0
