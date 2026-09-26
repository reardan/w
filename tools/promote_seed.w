/*
promote_seed: install a verified compiler as the local seed, backing the
old seed up first. Run by the update / update_win / update_darwin
targets in build.base.json (it replaced archive.sh, issue #323: no shell
scripts).

    promote_seed <seed> <new>

copies ./<seed> to ./old/<seed>_<dd_mm_yy_HH_MM_SS> (UTC), then copies
<new> to <seed>.new and renames it over <seed>, so the seed is never
half-written. A missing ./<seed> (seeds are downloaded, not committed)
skips the backup with a note.
*/
import lib.lib
import lib.time
import lib.stream
import structures.string


int promote_copy(char* from, char* to):
	int in = open(from, 0, 0)
	if (in < 0): return 1
	# 577 = O_WRONLY | O_CREAT | O_TRUNC, 493 = rwxr-xr-x
	int out = open(to, 577, 493)
	if (out < 0):
		close(in)
		return 1
	char* buf = malloc(65536)
	int failed = 0
	int n = read(in, buf, 65536)
	while (n > 0):
		if (write(out, buf, n) != n):
			failed = 1
			n = 0
		else: n = read(in, buf, 65536)
	if (n < 0): failed = 1
	free(buf)
	close(in)
	close(out)
	return failed


void promote_fail(char* message, char* detail):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"promote_seed: ")
	stream_write_cstr(err, message)
	stream_write_line(err, detail)
	stream_flush(err)
	exit(1)


char* promote_backup_name(char* seed):
	date_time* dt = new date_time()
	time_utc_from_unix(time_now(), dt)
	char* stamp = malloc(18)
	time_write_2_digits(stamp, dt.day)
	stamp[2] = '_'
	time_write_2_digits(stamp + 3, dt.month)
	stamp[5] = '_'
	time_write_2_digits(stamp + 6, dt.year % 100)
	stamp[8] = '_'
	time_write_2_digits(stamp + 9, dt.hour)
	stamp[11] = '_'
	time_write_2_digits(stamp + 12, dt.minute)
	stamp[14] = '_'
	time_write_2_digits(stamp + 15, dt.second)
	stamp[17] = 0
	string_builder* s = string_new()
	string_append(s, c"./old/")
	string_append(s, seed)
	string_append_char(s, '_')
	string_append(s, stamp)
	return s.data


int main(int argc, int argv):
	if (argc != 3): promote_fail(c"usage: promote_seed <seed> <new>", c"")
	char** seed_slot = argv + __word_size__
	char* seed = *seed_slot
	char** fresh_slot = argv + 2 * __word_size__
	char* fresh = *fresh_slot
	int probe = open(seed, 0, 0)
	if (probe < 0): println2(c"No existing seed to back up")
	else:
		close(probe)
		mkdir(c"old", 493)
		char* backup = promote_backup_name(seed)
		if (promote_copy(seed, backup)): promote_fail(c"cannot back up the seed to ", backup)
		print2(c"Backed up to ")
		println2(backup)
	string_builder* staged = string_new()
	string_append(staged, seed)
	string_append(staged, c".new")
	if (promote_copy(fresh, staged.data)): promote_fail(c"cannot copy the new seed from ", fresh)
	if (rename(staged.data, seed) != 0):
		promote_fail(c"cannot rename the new seed into place: ", seed)
	return 0
