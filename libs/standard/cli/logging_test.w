# wbuild: x64
# wbuild: step="bin/logging_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
# Tests for libs/standard/cli/logging.w, driven through the in-memory
# handler with a fixed clock.
import lib.testing
import lib.file
import lib.task
import lib.task_sync
import libs.standard.cli.logging


int fixed_clock_value


int fixed_clock():
	return fixed_clock_value


# Fresh module state, a deterministic clock, and a memory handler on the
# root logger with a short format.
log_handler* setup_memory(char* fmt):
	log_shutdown()
	fixed_clock_value = 1700000000     # 2023-11-14 22:13:20 UTC
	log_set_clock(fixed_clock)
	log_handler* h = log_memory_handler_new()
	log_handler_set_format(h, fmt)
	log_add_handler(log_root(), h)
	return h


void test_level_names():
	assert_strings_equal(c"DEBUG", log_level_name(LOG_DEBUG))
	assert_strings_equal(c"INFO", log_level_name(LOG_INFO))
	assert_strings_equal(c"WARNING", log_level_name(LOG_WARNING))
	assert_strings_equal(c"ERROR", log_level_name(LOG_ERROR))
	assert_strings_equal(c"CRITICAL", log_level_name(LOG_CRITICAL))
	assert_strings_equal(c"NOTSET", log_level_name(LOG_NOTSET))
	assert_equal(0, cast(int, log_level_name(15)))
	assert_equal(LOG_WARNING, log_level_from_name(c"WARN"))
	assert_equal(LOG_CRITICAL, log_level_from_name(c"FATAL"))
	assert_equal(LOG_DEBUG, log_level_from_name(c"DEBUG"))
	assert_equal(-1, log_level_from_name(c"debug"))
	assert_equal(-1, log_level_from_name(0))


void test_root_defaults_to_warning():
	log_handler* h = setup_memory(c"%(levelname)s:%(name)s:%(message)s")
	logger* root = log_root()
	assert_strings_equal(c"root", root.name)
	assert_equal(LOG_WARNING, log_effective_level(root))
	assert1(log_get_logger(0) == root)
	assert1(log_get_logger(c"") == root)
	assert1(log_get_logger(c"root") == root)
	log_debug(root, c"d")
	log_info(root, c"i")
	log_warning(root, c"w")
	log_error(root, c"e")
	log_critical(root, c"c")
	assert_equal(3, log_memory_count(h))
	assert_strings_equal(c"WARNING:root:w", log_memory_line(h, 0))
	assert_strings_equal(c"ERROR:root:e", log_memory_line(h, 1))
	assert_strings_equal(c"CRITICAL:root:c", log_memory_line(h, 2))
	assert_equal(LOG_CRITICAL, log_memory_level(h, 2))
	log_shutdown()


void test_hierarchy_and_effective_level():
	log_handler* h = setup_memory(c"%(name)s %(message)s")
	logger* ab = log_get_logger(c"a.b")
	logger* a = log_get_logger(c"a")
	assert1(ab.parent == a)
	assert1(a.parent == log_root())
	assert1(log_get_logger(c"a.b") == ab)
	assert1(log_get_child(a, c"b") == ab)
	assert1(log_get_child(log_root(), c"a") == a)
	logger* abc = log_get_logger(c"a.b.c")
	assert1(abc.parent == ab)

	# Everything NOTSET below root inherits WARNING.
	assert_equal(LOG_NOTSET, ab.level)
	assert_equal(LOG_WARNING, log_effective_level(abc))
	log_set_level(a, LOG_DEBUG)
	assert_equal(LOG_DEBUG, log_effective_level(abc))
	log_set_level(ab, LOG_ERROR)
	assert_equal(LOG_ERROR, log_effective_level(abc))
	assert_equal(LOG_DEBUG, log_effective_level(a))
	assert_equal(0, log_is_enabled_for(abc, LOG_WARNING))
	assert_equal(1, log_is_enabled_for(abc, LOG_ERROR))

	log_info(a, c"a info")          # a is DEBUG: passes, root handler emits
	log_warning(abc, c"dropped")    # below a.b's ERROR
	log_error(abc, c"kept")
	assert_equal(2, log_memory_count(h))
	assert_strings_equal(c"a a info", log_memory_line(h, 0))
	assert_strings_equal(c"a.b.c kept", log_memory_line(h, 1))
	log_shutdown()


void test_sibling_prefix_is_not_parent():
	log_handler* h = setup_memory(c"%(name)s")
	logger* ab = log_get_logger(c"ab")
	logger* abc = log_get_logger(c"ab.c")
	logger* a = log_get_logger(c"a")
	assert1(ab.parent == log_root())
	assert1(abc.parent == ab)
	assert1(a.parent == log_root())
	log_set_level(a, LOG_DEBUG)
	assert_equal(LOG_WARNING, log_effective_level(abc))
	assert_equal(0, log_memory_count(h))
	log_shutdown()


void test_propagate_and_handler_levels():
	log_handler* root_h = setup_memory(c"root %(message)s")
	logger* svc = log_get_logger(c"svc")
	logger* db = log_get_logger(c"svc.db")
	log_set_level(svc, LOG_DEBUG)
	log_handler* svc_h = log_memory_handler_new()
	log_handler_set_format(svc_h, c"svc %(message)s")
	log_add_handler(svc, svc_h)
	log_add_handler(svc, svc_h)      # adding twice is a no-op
	log_handler* db_h = log_memory_handler_new()
	log_handler_set_format(db_h, c"db %(message)s")
	log_handler_set_level(db_h, LOG_WARNING)
	log_add_handler(db, db_h)

	log_info(db, c"one")             # db_h filters it; svc_h and root_h take it
	assert_equal(0, log_memory_count(db_h))
	assert_equal(1, log_memory_count(svc_h))
	assert_equal(1, log_memory_count(root_h))
	log_warning(db, c"two")
	assert_equal(1, log_memory_count(db_h))
	assert_equal(2, log_memory_count(svc_h))
	assert_strings_equal(c"db two", log_memory_line(db_h, 0))
	assert_strings_equal(c"svc two", log_memory_line(svc_h, 1))
	assert_strings_equal(c"root two", log_memory_line(root_h, 1))

	# A logger with propagate off still emits to its own handlers but
	# stops the walk there.
	log_set_propagate(svc, 0)
	log_error(db, c"three")
	assert_equal(2, log_memory_count(db_h))
	assert_equal(3, log_memory_count(svc_h))
	assert_equal(2, log_memory_count(root_h))
	log_set_propagate(db, 0)
	log_error(db, c"four")
	assert_equal(3, log_memory_count(db_h))
	assert_equal(3, log_memory_count(svc_h))
	assert_equal(1, log_has_handlers(db))
	log_remove_handler(db, db_h)
	assert_equal(0, log_has_handlers(db))
	assert_equal(1, log_has_handlers(svc))

	# The logger level, not the handler's ancestry, decides admission.
	log_set_level(db, LOG_CRITICAL)
	log_set_propagate(db, 1)
	log_error(db, c"five")
	assert_equal(3, log_memory_count(svc_h))
	log_shutdown()


void test_format_fields():
	log_handler* h = setup_memory(c"%(asctime)s|%(created)s|%(levelno)s|%(levelname)s|%(name)s|%(message)s|100%%|%(bogus)s|%(")
	logger* lg = log_get_logger(c"x.y")
	log_error(lg, c"msg")
	assert_strings_equal(c"2023-11-14 22:13:20|1700000000|40|ERROR|x.y|msg|100%|%(bogus)s|%(", log_memory_line(h, 0))
	log_log(lg, 35, c"custom")
	log_handler_set_format(h, c"%(levelname)s %(levelno)d %(created)d")
	log_log(lg, 45, c"x")
	assert_strings_equal(c"Level 45 45 1700000000", log_memory_line(h, 2))
	log_log(lg, 5, c"too low")
	assert_equal(3, log_memory_count(h))
	log_shutdown()


void test_default_format_and_clock():
	log_handler* h = setup_memory(0)
	logger* lg = log_get_logger(c"app")
	log_warning(lg, c"started")
	fixed_clock_value = 0
	log_warning(lg, c"epoch")
	assert_strings_equal(c"2023-11-14 22:13:20 WARNING app: started", log_memory_line(h, 0))
	assert_strings_equal(c"1970-01-01 00:00:00 WARNING app: epoch", log_memory_line(h, 1))
	log_memory_clear(h)
	assert_equal(0, log_memory_count(h))
	# Restoring the real clock still produces a 19-character timestamp.
	log_set_clock(0)
	log_handler_set_format(h, c"%(asctime)s")
	log_warning(lg, c"now")
	assert_equal(19, strlen(log_memory_line(h, 0)))
	log_shutdown()


void test_disable_and_disabled_logger():
	log_handler* h = setup_memory(c"%(message)s")
	logger* lg = log_get_logger(c"q")
	log_set_level(lg, LOG_DEBUG)
	log_disable(LOG_INFO)
	log_info(lg, c"no")
	log_warning(lg, c"yes")
	log_disable(LOG_NOTSET)
	log_debug(lg, c"again")
	log_set_disabled(lg, 1)
	log_critical(lg, c"silent")
	log_set_disabled(lg, 0)
	assert_equal(2, log_memory_count(h))
	assert_strings_equal(c"yes", log_memory_line(h, 0))
	assert_strings_equal(c"again", log_memory_line(h, 1))
	log_shutdown()


/* A custom handler through the interface, which also logs re-entrantly. */

struct counting_sink:
	int calls
	int closed
	int last_level
	logger* echo_to


void counting_emit(void* self, log_record* r, char* line):
	counting_sink* s = cast(counting_sink*, self)
	s.calls = s.calls + 1
	s.last_level = r.level
	if ((cast(int, s.echo_to) != 0) && (s.calls == 1)):
		log_error(s.echo_to, line)


void counting_close(void* self):
	counting_sink* s = cast(counting_sink*, self)
	s.closed = s.closed + 1


void test_custom_handler_and_reentrancy():
	log_handler* mem = setup_memory(c"mem %(message)s")
	counting_sink sink
	sink.calls = 0
	sink.closed = 0
	sink.last_level = 0
	sink.echo_to = log_root()
	log_handler* h = log_handler_new(cast(void*, &sink), counting_emit, counting_close)
	log_handler_set_format(h, c"[%(message)s]")
	log_add_handler(log_root(), h)
	log_error(log_root(), c"boom")
	# The sink saw "boom" and its own echo "[boom]"; the memory handler too.
	assert_equal(2, sink.calls)
	assert_equal(2, log_memory_count(mem))
	# mem was added first, so it saw "boom" before the sink echoed it.
	assert_strings_equal(c"mem boom", log_memory_line(mem, 0))
	assert_strings_equal(c"mem [boom]", log_memory_line(mem, 1))
	log_handler_free(h)
	assert_equal(1, sink.closed)
	assert_equal(1, log_root().handlers.length)
	log_error(log_root(), c"after")
	assert_equal(2, sink.calls)
	log_shutdown()


void test_custom_handler_closed_by_shutdown():
	log_shutdown()
	counting_sink sink
	sink.calls = 0
	sink.closed = 0
	sink.echo_to = 0
	log_handler* h = log_handler_new(cast(void*, &sink), counting_emit, 0)
	log_handler_free(h)
	log_handler* h2 = log_handler_new(cast(void*, &sink), counting_emit, counting_close)
	log_add_handler(log_get_logger(c"k.l"), h2)
	log_critical(log_get_logger(c"k.l.m"), c"x")
	assert_equal(1, sink.calls)
	assert_equal(LOG_CRITICAL, sink.last_level)
	log_shutdown()
	assert_equal(1, sink.closed)


void test_file_handler_appends():
	log_shutdown()
	fixed_clock_value = 86400
	log_set_clock(fixed_clock)
	char* path = c"bin/logging_test_file.log"
	unlink(path)
	log_handler* h = log_file_handler_new(path)
	assert1(cast(int, h) != 0)
	log_add_handler(log_root(), h)
	log_warning(log_get_logger(c"f"), c"first")
	log_handler_free(h)
	h = log_file_handler_new(path)
	log_handler_set_format(h, c"%(levelname)s %(message)s")
	log_add_handler(log_root(), h)
	log_error(log_root(), c"second")
	assert_equal(0, log_handler_errors(h))
	log_shutdown()
	char* text = file_read_text(path)
	assert_strings_equal(c"1970-01-02 00:00:00 WARNING f: first\nERROR second\n", text)
	free(text)
	unlink(path)
	assert_equal(0, cast(int, log_file_handler_new(c"bin/no/such/dir/x.log")))
	log_shutdown()


void test_basic_config():
	log_shutdown()
	log_handler* h = log_basic_config(LOG_INFO, c"%(message)s")
	assert1(cast(int, h) != 0)
	assert_equal(LOG_INFO, log_effective_level(log_get_logger(c"z")))
	assert_equal(0, cast(int, log_basic_config(LOG_DEBUG, 0)))
	assert_equal(LOG_INFO, log_root().level)
	assert_equal(2, h.fd)
	log_shutdown()


/* Tasks: a handler's lock keeps lines whole across tasks. */

generator int hold_handler_lock(log_handler* h, list[int] order):
	assert_equal(1, log_lock_acquire(h.lock))
	order.push(1)
	task_yield_now()
	task_yield_now()
	order.push(2)
	log_lock_release(h.lock)


generator int log_from_task(logger* lg, list[int] order):
	order.push(10)
	log_error(lg, c"from task")
	order.push(20)


void test_lock_serializes_tasks():
	log_handler* h = setup_memory(c"%(message)s")
	logger* lg = log_get_logger(c"t")
	list[int] order = new list[int]
	task_scheduler* s = task_scheduler_new()
	task_spawn(s, hold_handler_lock(h, order))
	task_spawn(s, log_from_task(lg, order))
	assert_equal(0, task_run(s))
	# The logging task parked on the held lock until it was released.
	assert_equal(4, order.length)
	assert_equal(1, order[0])
	assert_equal(10, order[1])
	assert_equal(2, order[2])
	assert_equal(20, order[3])
	assert_equal(1, log_memory_count(h))
	assert_strings_equal(c"from task", log_memory_line(h, 0))
	assert_equal(0, h.lock.mutex.locked)
	assert_equal(0, h.lock.depth)
	order.free()
	task_scheduler_free(s)
	log_shutdown()
