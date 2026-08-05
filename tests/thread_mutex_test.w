# wbuild: x64
import lib.testing
import lib.thread

/*
wmutex/wcond (lib/thread.w): mutual exclusion under real multi-core
contention, then the condvar's wait/signal/broadcast protocol.

The mutex test is the load-bearing one: each worker performs a plain
multi-instruction read-modify-write (`counter = counter + 1`) plus a
two-word invariant update inside the critical section. Nothing about
those accesses is atomic — with these iteration counts, unlocked
concurrent workers would overwhelmingly likely interleave, losing
counts and tearing the invariant — so the exact final count and the
intact invariant deterministically pin down the positive contract:
the lock really serializes the section and its stores are visible to
the next holder. (A lost-update assertion for the unlocked variant
can never be made deterministic, so it is not attempted.)

The condvar tests only ever park with the predicate re-checked under
the mutex, so they are deterministic regardless of scheduling: a
worker that arrives after the flip never waits, one that parked is
woken by the signal/broadcast that follows the flip.
*/

wmutex* counter_mutex
int plain_counter
int invariant_a
int invariant_b

wcond* go_cond
wmutex* go_mutex
int go_flag
int go_acks

int pingpong_turn   # 0: main may step, 1: worker may step
int pingpong_count


void mutex_worker(void* arg):
	int n = cast(int, arg)
	int i = 0
	while (i < n):
		mutex_lock(counter_mutex)
		# non-atomic read-modify-writes, safe only under the lock
		plain_counter = plain_counter + 1
		int v = invariant_a + 1
		invariant_a = v
		invariant_b = v
		mutex_unlock(counter_mutex)
		i = i + 1


void test_mutex_exact_under_contention():
	counter_mutex = new wmutex()
	mutex_init(counter_mutex)
	plain_counter = 0
	invariant_a = 0
	invariant_b = 0
	int per_thread = 25000
	wthread*[4] threads
	int i = 0
	while (i < 4):
		threads[i] = thread_spawn(mutex_worker, cast(void*, per_thread))
		asserts(c"thread_spawn failed", cast(int, threads[i]) != 0)
		i = i + 1
	i = 0
	while (i < 4):
		assert_equal(0, thread_join(threads[i]))
		i = i + 1
	assert_equal(4 * per_thread, plain_counter)
	assert_equal(4 * per_thread, invariant_a)
	assert_equal(invariant_a, invariant_b)
	free(cast(void*, counter_mutex))


void broadcast_worker(void* arg):
	mutex_lock(go_mutex)
	while (go_flag == 0):
		cond_wait(go_cond, go_mutex)
	mutex_unlock(go_mutex)
	atomic_add(&go_acks, 1)


void test_cond_broadcast_releases_all_waiters():
	go_mutex = new wmutex()
	go_cond = new wcond()
	mutex_init(go_mutex)
	cond_init(go_cond)
	go_flag = 0
	go_acks = 0
	wthread*[3] threads
	int i = 0
	while (i < 3):
		threads[i] = thread_spawn(broadcast_worker, cast(void*, 0))
		asserts(c"thread_spawn failed", cast(int, threads[i]) != 0)
		i = i + 1
	# flip the predicate under the mutex, then wake everyone
	mutex_lock(go_mutex)
	go_flag = 1
	mutex_unlock(go_mutex)
	cond_broadcast(go_cond)
	i = 0
	while (i < 3):
		assert_equal(0, thread_join(threads[i]))
		i = i + 1
	assert_equal(3, go_acks)
	free(cast(void*, go_mutex))
	free(cast(void*, go_cond))


void pingpong_worker(void* arg):
	int rounds = cast(int, arg)
	int i = 0
	while (i < rounds):
		mutex_lock(go_mutex)
		while (pingpong_turn == 0):
			cond_wait(go_cond, go_mutex)
		pingpong_count = pingpong_count + 1
		pingpong_turn = 0
		cond_signal(go_cond)
		mutex_unlock(go_mutex)
		i = i + 1


# Strict alternation driven entirely by cond_signal in both directions:
# each side may only step on its own turn and hands the turn back with
# a signal. Any lost wakeup deadlocks (the test would hang, not
# corrupt); the exact count shows every round completed.
void test_cond_signal_pingpong():
	go_mutex = new wmutex()
	go_cond = new wcond()
	mutex_init(go_mutex)
	cond_init(go_cond)
	pingpong_turn = 0
	pingpong_count = 0
	int rounds = 1000
	wthread* t = thread_spawn(pingpong_worker, cast(void*, rounds))
	asserts(c"thread_spawn failed", cast(int, t) != 0)
	int i = 0
	while (i < rounds):
		mutex_lock(go_mutex)
		while (pingpong_turn == 1):
			cond_wait(go_cond, go_mutex)
		pingpong_turn = 1
		cond_signal(go_cond)
		mutex_unlock(go_mutex)
		i = i + 1
	assert_equal(0, thread_join(t))
	assert_equal(rounds, pingpong_count)
	assert_equal(0, pingpong_turn)
	free(cast(void*, go_mutex))
	free(cast(void*, go_cond))
