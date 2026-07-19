/*
Owner/group name lookup without NSS.

Parses /etc/passwd and /etc/group directly (colon-separated fields).
Enough for `stat` / `ls -l` style display and rare chown-by-name CLIs;
no getpwuid/getgrgid, no libc, no network user databases.

Path-taking `*_at` helpers accept a fixture file for tests. The
convenience wrappers use the live system paths.

Design notes: docs/projects/unix_primitives.md.
*/
import lib.lib
import lib.file
import lib.str


char* PASSWD_PATH():
	return c"/etc/passwd"


char* GROUP_PATH():
	return c"/etc/group"


void passwd_free_lines(list[char*] lines):
	if (lines == 0):
		return
	for char* line in lines:
		free(line)
	free(cast(void*, lines))


void passwd_free_fields(list[char*] fields):
	if (fields == 0):
		return
	for char* field in fields:
		free(field)
	free(cast(void*, fields))


# Skip blank lines and `#` comments. Returns 1 when the line should be
# parsed as a database record.
int passwd_line_usable(char* line):
	if (line == 0):
		return 0
	if (line[0] == 0):
		return 0
	if (line[0] == '#'):
		return 0
	return 1


# Look up a numeric id in a passwd/group-style file. `id_field` is the
# 0-based index of the uid/gid column (2 for passwd, 2 for group).
# Returns a fresh malloc'd name, or 0 when missing / unreadable.
char* passwd_id_name_at(char* path, int id, int id_field):
	list[char*] lines = file_read_lines(path)
	if (lines == 0):
		return 0
	char* found = 0
	for char* line in lines:
		if (passwd_line_usable(line)):
			list[char*] fields = split(line, ':')
			if (fields.length > id_field):
				if (atoi(fields[id_field]) == id):
					found = strclone(fields[0])
			passwd_free_fields(fields)
		if (found != 0):
			break
	passwd_free_lines(lines)
	return found


# Look up a name in a passwd/group-style file. Returns the numeric id,
# or -1 when missing / unreadable.
int passwd_name_id_at(char* path, char* name, int id_field):
	if (name == 0):
		return 0 - 1
	list[char*] lines = file_read_lines(path)
	if (lines == 0):
		return 0 - 1
	int found = 0 - 1
	for char* line in lines:
		if (passwd_line_usable(line)):
			list[char*] fields = split(line, ':')
			if (fields.length > id_field):
				if (strcmp(fields[0], name) == 0):
					found = atoi(fields[id_field])
			passwd_free_fields(fields)
		if (found >= 0):
			break
	passwd_free_lines(lines)
	return found


char* passwd_uid_name_at(char* path, int uid):
	return passwd_id_name_at(path, uid, 2)


char* passwd_gid_name_at(char* path, int gid):
	return passwd_id_name_at(path, gid, 2)


int passwd_name_uid_at(char* path, char* name):
	return passwd_name_id_at(path, name, 2)


int passwd_name_gid_at(char* path, char* name):
	return passwd_name_id_at(path, name, 2)


char* passwd_uid_name(int uid):
	return passwd_uid_name_at(PASSWD_PATH(), uid)


char* passwd_gid_name(int gid):
	return passwd_gid_name_at(GROUP_PATH(), gid)


int passwd_name_uid(char* name):
	return passwd_name_uid_at(PASSWD_PATH(), name)


int passwd_name_gid(char* name):
	return passwd_name_gid_at(GROUP_PATH(), name)
