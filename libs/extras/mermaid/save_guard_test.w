# wbuild: x64 arch=win64
# Compare-and-swap saves and disk polling, including writers that race
# each stage of the save (injected through mm_save_race_hook).
import lib.testing
import lib.dir
import lib.file
import libs.extras.mermaid.editor

char* sg_dir = c"bin/mermaid_save_guard"
char* sg_racer_bytes
int sg_racer_stage
int sg_racer_fd
int sg_racer_mode

void sg_reset_dir():
	mkdir(c"bin", 493)
	mkdir(sg_dir, 493)
	for char* name in dir_names(sg_dir):
		string_builder* full = string_from(sg_dir)
		string_append_char(full, '/')
		string_append(full, name)
		unlink(full.data)
		string_free(full)

char* sg_path(char* name):
	string_builder* full = string_from(sg_dir)
	string_append_char(full, '/')
	string_append(full, name)
	char* text = full.data
	free(full)
	return text

# Another program's write: a replace-by-rename where lib.fs exists, a plain
# truncating write on Windows (which has no lib.fs adapter).
void sg_write(char* path, char* text):
	io_result result
	if (os_windows()):
		assert_equal(IO_OK, file_write_text_checked(path, text, strlen(text), &result))
		return
	assert_equal(IO_OK, file_write_durable(path, text, strlen(text), &result))

char* sg_read(char* path):
	int length = 0
	char* text = mm_read_source(path, &length)
	asserts(c"file readable", text != 0)
	return text

# Only the target (and an explicit recovery file) may remain: no staged
# temp files or claims leak from any outcome.
int sg_leftovers():
	int count = 0
	for char* name in dir_names(sg_dir):
		if (contains(name, c".tmp.") || contains(name, c".claim.")): count = count + 1
	return count

# The racer: mode 0 replaces the file (rename-based writer), mode 1 writes
# in place through a descriptor opened before the save, mode 2 deletes it.
int sg_racer(char* path, int stage):
	if (stage != sg_racer_stage): return 0
	if (sg_racer_mode == 0): sg_write(path, sg_racer_bytes)
	if (sg_racer_mode == 1):
		io_result result
		fs_pwrite_all(sg_racer_fd, sg_racer_bytes, strlen(sg_racer_bytes), 0, &result)
	if (sg_racer_mode == 2): unlink(path)
	return 1

void sg_race(int stage, int mode, char* bytes):
	sg_racer_stage = stage
	sg_racer_mode = mode
	sg_racer_bytes = bytes
	mm_save_race_hook = sg_racer

void sg_no_race():
	mm_save_race_hook = 0

void test_clean_save_replaces_via_temp_and_leaves_nothing_behind():
	sg_reset_dir()
	char* path = sg_path(c"clean.mmd")
	sg_write(path, c"flowchart LR\nA\n")
	file_chmod(path, 384)
	mm_editor* e = mm_editor_open(path)
	mm_editor_change(e, c"flowchart LR\nA --> B\n")
	assert_equal(MM_SAVE_OK, mm_editor_save_checked(e))
	assert_strings_equal(c"flowchart LR\nA --> B\n", sg_read(path))
	assert_equal(0, mm_editor_dirty(e))
	assert_equal(0, sg_leftovers())
	if (os_windows() == 0):
		file_stat st
		assert_equal(0, file_stat_path(path, &st))
		assert_equal(384, st.mode & FILE_MODE_PERM_MASK)
	assert_equal(MM_DISK_SAME, mm_editor_poll(e, 1))
	mm_editor_free(e)

void test_external_edit_before_save_is_a_conflict_and_never_overwritten():
	sg_reset_dir()
	char* path = sg_path(c"edited.mmd")
	sg_write(path, c"flowchart LR\nA\n")
	mm_editor* e = mm_editor_open(path)
	mm_editor_change(e, c"flowchart LR\nMine\n")
	# Same size as the original: only a content comparison can tell.
	sg_write(path, c"flowchart LR\nZ\n")
	assert_equal(MM_DISK_CHANGED, mm_editor_poll(e, 1))
	assert_equal(MM_SAVE_CONFLICT, mm_editor_save_checked(e))
	assert_strings_equal(c"flowchart LR\nZ\n", sg_read(path))
	assert_equal(1, mm_editor_dirty(e))
	assert_equal(0, sg_leftovers())
	# Keep mine: the user saw the change and chose to replace exactly it.
	assert_equal(1, mm_editor_keep_mine(e))
	assert_equal(MM_DISK_SAME, mm_editor_poll(e, 1))
	assert_equal(MM_SAVE_OK, mm_editor_save_checked(e))
	assert_strings_equal(c"flowchart LR\nMine\n", sg_read(path))
	mm_editor_free(e)

void test_deleted_file_is_reported_missing_then_recreated_only_on_request():
	sg_reset_dir()
	char* path = sg_path(c"deleted.mmd")
	sg_write(path, c"flowchart LR\nA\n")
	mm_editor* e = mm_editor_open(path)
	unlink(path)
	assert_equal(MM_DISK_MISSING, mm_editor_poll(e, 0))
	assert_equal(MM_SAVE_CONFLICT, mm_editor_save_checked(e))
	assert_equal(0, mm_disk_present(path))
	assert_equal(1, mm_editor_keep_mine(e))
	assert_equal(MM_SAVE_OK, mm_editor_save_checked(e))
	assert_strings_equal(c"flowchart LR\nA\n", sg_read(path))
	mm_editor_free(e)

void test_poll_fingerprint_skips_reads_until_force():
	sg_reset_dir()
	char* path = sg_path(c"poll.mmd")
	sg_write(path, c"flowchart LR\nA\n")
	mm_editor* e = mm_editor_open(path)
	assert_equal(MM_DISK_SAME, mm_editor_poll(e, 0))
	# A replacement changes the inode, so even an unforced poll sees it.
	sg_write(path, c"flowchart LR\nAB\n")
	assert_equal(MM_DISK_CHANGED, mm_editor_poll(e, 0))
	assert_equal(MM_DISK_CHANGED, mm_editor_poll(e, 0))
	assert_equal(1, mm_editor_reload(e))
	assert_equal(MM_DISK_SAME, mm_editor_poll(e, 0))
	assert_strings_equal(c"flowchart LR\nAB\n", e.document.source)
	mm_editor_free(e)

void test_writer_racing_the_precheck_keeps_its_bytes():
	sg_reset_dir()
	char* path = sg_path(c"race1.mmd")
	sg_write(path, c"flowchart LR\nA\n")
	mm_editor* e = mm_editor_open(path)
	mm_editor_change(e, c"flowchart LR\nMine\n")
	sg_race(1, 0, c"flowchart LR\nTheirs\n")
	assert_equal(MM_SAVE_CONFLICT, mm_editor_save_checked(e))
	sg_no_race()
	assert_strings_equal(c"flowchart LR\nTheirs\n", sg_read(path))
	assert_equal(0, cast(int, e.recovery_path))
	assert_equal(0, sg_leftovers())
	assert_equal(1, mm_editor_dirty(e))
	mm_editor_free(e)

void test_writer_creating_the_path_after_the_claim_wins():
	sg_reset_dir()
	char* path = sg_path(c"race2.mmd")
	sg_write(path, c"flowchart LR\nA\n")
	mm_editor* e = mm_editor_open(path)
	mm_editor_change(e, c"flowchart LR\nMine\n")
	sg_race(2, 0, c"flowchart LR\nTheirs\n")
	assert_equal(MM_SAVE_CONFLICT, mm_editor_save_checked(e))
	sg_no_race()
	assert_strings_equal(c"flowchart LR\nTheirs\n", sg_read(path))
	assert_equal(0, sg_leftovers())
	assert_equal(1, mm_editor_dirty(e))
	mm_editor_free(e)

void test_in_place_writer_after_placement_is_recovered_not_lost():
	# Positional writes need lib.fs, which Windows does not have.
	if (os_windows()): return
	sg_reset_dir()
	char* path = sg_path(c"race3.mmd")
	sg_write(path, c"flowchart LR\nA\n")
	mm_editor* e = mm_editor_open(path)
	mm_editor_change(e, c"flowchart LR\nMine\n")
	io_result result
	sg_racer_fd = fs_open(path, FS_O_RDWR, 0, &result)
	asserts(c"racer descriptor", sg_racer_fd >= 0)
	sg_race(3, 1, c"flowchart LR\nB\n")
	assert_equal(MM_SAVE_CONFLICT, mm_editor_save_checked(e))
	sg_no_race()
	io_close(sg_racer_fd, &result)
	assert_strings_equal(c"flowchart LR\nMine\n", sg_read(path))
	asserts(c"recovery copy kept", e.recovery_path != 0)
	assert_strings_equal(c"flowchart LR\nB\n", sg_read(e.recovery_path))
	unlink(e.recovery_path)
	mm_editor_clear_recovery(e)
	assert_equal(0, sg_leftovers())
	mm_editor_free(e)

void test_delete_racing_the_save_is_a_conflict():
	sg_reset_dir()
	char* path = sg_path(c"race4.mmd")
	sg_write(path, c"flowchart LR\nA\n")
	mm_editor* e = mm_editor_open(path)
	mm_editor_change(e, c"flowchart LR\nMine\n")
	sg_race(1, 2, 0)
	assert_equal(MM_SAVE_CONFLICT, mm_editor_save_checked(e))
	sg_no_race()
	assert_equal(0, mm_disk_present(path))
	assert_equal(0, sg_leftovers())
	mm_editor_free(e)

void test_new_file_never_replaces_one_created_meanwhile():
	sg_reset_dir()
	char* path = sg_path(c"new.mmd")
	mm_editor* e = mm_editor_new(path, c"flowchart LR\nMine\n")
	assert_equal(MM_DISK_SAME, mm_editor_poll(e, 1))
	sg_race(2, 0, c"flowchart LR\nTheirs\n")
	assert_equal(MM_SAVE_CONFLICT, mm_editor_save_checked(e))
	sg_no_race()
	assert_strings_equal(c"flowchart LR\nTheirs\n", sg_read(path))
	assert_equal(0, sg_leftovers())
	unlink(path)
	assert_equal(MM_SAVE_OK, mm_editor_save_checked(e))
	assert_strings_equal(c"flowchart LR\nMine\n", sg_read(path))
	mm_editor_free(e)
