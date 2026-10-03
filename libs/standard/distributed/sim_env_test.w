# wbuild: x64
import lib.testing
import libs.standard.distributed.sim_env


/*
Nodes in a sim.w network, each with a sim-driven clock and its own
fake filesystem. Node 2 appends every delivered message to a log and
syncs only every other one; a crash then keeps the synced prefix and a
seeded part of the rest. Every run is a function of the seeds.
*/


void test_clocks_follow_sim_time():
	sim_net* net = sim_new(1, 0, 0, 0)
	sim_env* a = sim_env_new(net, 1, 9, 1700000000)
	sim_env* b = sim_env_new(net, 2, 9, 1700000000)
	sim_advance(net, 1500)
	int ms = 0
	assert_equal(IO_OK, wclock_monotonic_ms(sim_env_clock(a), &ms))
	assert_equal(1500, ms)
	sim_env_jump_wall_ms(b, 0 - 60000)
	wtime w
	assert_equal(IO_OK, wclock_wall(sim_env_clock(a), &w))
	assert_equal(1700000001, w.sec)
	assert_equal(500000000, w.nsec)
	assert_equal(IO_OK, wclock_wall(sim_env_clock(b), &w))
	assert_equal(1700000001 - 60, w.sec)
	# The jump left node 2's monotonic line alone.
	assert_equal(IO_OK, wclock_monotonic_ms(sim_env_clock(b), &ms))
	assert_equal(1500, ms)
	sim_env_free(a)
	sim_env_free(b)
	sim_free(net)


# Delivers every due message to node 2's log; returns how many.
int env_test_deliver(sim_net* net, sim_env* node2, int fd, int* sent_synced):
	file_ops* ops = sim_env_ops(node2)
	int from = 0
	int to = 0
	int n = 0
	char* payload = sim_take_due(net, &from, &to)
	while (cast(int, payload) != 0):
		io_result r
		assert_equal(IO_OK, file_ops_write_all(ops, fd, payload, strlen(payload), &r))
		n = n + 1
		if ((n % 2) == 0):
			assert_equal(IO_OK, file_ops_sync(ops, fd, &r))
			sent_synced[0] = sent_synced[0] + 1
		payload = sim_take_due(net, &from, &to)
	return n


# Runs the scenario; returns node 2's log size after its crash.
int env_test_run(int seed, int* hash_out):
	sim_net* net = sim_new(seed, 1, 30, 100)
	sim_env* node2 = sim_env_new(net, 2, seed, 0)
	file_ops* ops = sim_env_ops(node2)
	io_result r
	int fd = -1
	assert_equal(IO_OK, file_ops_open(ops, c"log", FILE_OPS_WRITE | FILE_OPS_CREATE | FILE_OPS_APPEND, 420, &fd, &r))
	assert_equal(IO_OK, file_ops_sync_dir(ops, c".", &r))
	int synced = 0
	int delivered = 0
	for i in range(20):
		sim_send(net, 1, 2, c"0123456789")
		sim_advance(net, 5)
		delivered = delivered + env_test_deliver(net, node2, fd, &synced)
	sim_advance(net, 100)
	delivered = delivered + env_test_deliver(net, node2, fd, &synced)
	assert_equal(delivered * 10, fake_fs_file_size(node2.fs, c"log"))
	sim_env_crash(node2)
	int size = fake_fs_file_size(node2.fs, c"log")
	# At least every synced record survives; nothing beyond what was written.
	assert1(size >= synced * 2 * 10)
	assert1(size <= delivered * 10)
	hash_out[0] = fake_fs_state_hash(node2.fs)
	sim_env_free(node2)
	sim_free(net)
	return size


void test_node_crash_replays_from_seed():
	int h1 = 0
	int h2 = 0
	int s1 = env_test_run(77, &h1)
	int s2 = env_test_run(77, &h2)
	assert_equal(s1, s2)
	assert_equal(h1, h2)
	list[int] sizes = new list[int]
	for seed in range(1, 11):
		int h = 0
		int s = env_test_run(seed, &h)
		if ((s in sizes) == 0): sizes.push(s)
	assert1(sizes.length >= 2)
	list_free[int](sizes)
