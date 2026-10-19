# Identity of actual working sources, including nonignored untracked files.
import tools.host_tools
import lib.str
import libs.standard.crypto.sha2

char* vsi_digest(char* path):
	string_builder* data = ht_read(path)
	char* digest = ht_digest(data.data, data.length)
	string_free(data)
	return digest

json_value* source_identity():
	char* root = strip(ht_checked(ht_command(c"git rev-parse --show-toplevel")).stdout_text)
	spawn_options* options = spawn_options_new()
	options.cwd = root
	process_result* listed = ht_run(ht_command(c"git ls-files --cached --others --exclude-standard -z"), options, 0, 30000)
	ht_success(listed)
	set[char*] unique = new set[char*]
	int start = 0
	for i in range(listed.stdout_length):
		if (listed.stdout_text[i] == 0):
			if (i > start): unique.add(path_clone_range(listed.stdout_text + start, i - start))
			start = i + 1
	list[char*] names = unique.keys()
	ht_sort(names)
	whash* tree = whash_new(WHASH_SHA256)
	int count = 0
	for char* name in names:
		char* path = path_join(root, name)
		file_stat st
		if (file_lstat_path(path, &st) != 0): continue
		char* kind = c"file"
		string_builder* data = 0
		if ((st.mode & FILE_S_IFMT) == FILE_S_IFLNK):
			char[4096] target
			int length = readlink(path, &target[0], 4096)
			ht_require(length >= 0 && length < 4096, c"cannot hash symlink")
			data = string_new()
			string_append_bytes(data, &target[0], length)
			kind = c"symlink"
		elif ((st.mode & FILE_S_IFMT) == FILE_S_IFREG):
			data = ht_read(path)
			if ((st.mode & 73) != 0): kind = c"executable"
		else: continue
		for char* field in ht_argv(name, kind, itoa(data.length)): whash_update(tree, field, strlen(field) + 1)
		whash_update(tree, data.data, data.length)
		string_free(data)
		count = count + 1
	char[32] digest
	whash_final(tree, &digest[0])
	whash_free(tree)
	process_result* diff = ht_run(ht_command(c"git diff --binary HEAD"), options, 0, 30000)
	ht_success(diff)
	json_value* result = json_object()
	json_object_set(result, c"tree_sha256", json_string(hex_encode(&digest[0], 32)))
	json_object_set(result, c"files", json_int(count))
	json_object_set(result, c"diff_head_binary_sha256", json_string(ht_digest(diff.stdout_text, diff.stdout_length)))
	json_object_set(result, c"tree_algorithm", json_string(c"sha256 of sorted tracked and nonignored untracked files: path NUL kind NUL decimal byte length NUL content; deleted files absent; symlinks hash link text"))
	return result
