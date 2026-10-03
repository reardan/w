/*
Per-node environment for sim.w scenarios (docs/projects/simulation.md):
each simulated node owns a clock that follows the network's virtual
time and a fake filesystem (lib/fake_fs.w) that crashes with it, so
storage and timing code written against lib/wclock.w and
lib/file_ops.w runs inside the deterministic simulator unchanged.

- Clock: monotonic time is sim_now (ms since sim_new) - every node sees
  the same monotonic line, advanced only by sim_advance. Wall time is
  wall_base_sec + sim_now plus a per-node offset that the test steps
  with sim_env_jump_wall_ms (NTP steps, skew between nodes) without
  touching monotonic time.
- Storage: sim_env_crash(env) is a power loss on that node only. Its
  outcome is drawn from a per-node prng seeded from (seed, node), and
  the fs's fault schedule from another, so a run stays a pure function
  of (seed, call script) like the rest of sim.w.

The env borrows the sim_net; free envs before or after sim_free, in
either order. Nothing here changes sim.w's own behaviour.
*/
import lib.lib
import lib.assert
import lib.wclock
import lib.fake_fs
import libs.standard.distributed.sim
import libs.standard.distributed.prng


struct sim_env:
	sim_net* net
	int node
	wclock* clock
	fake_fs* fs
	prng* crash_rng
	int wall_base_sec
	int wall_offset_ms


int sim_env_read(void* self, int which, wtime* out):
	sim_env* env = cast(sim_env*, self)
	int now = sim_now(env.net)
	if (which == WCLOCK_WALL):
		wtime_set(out, env.wall_base_sec, 0)
		wtime_add_ms(out, now)
		wtime_add_ms(out, env.wall_offset_ms)
		return IO_OK
	wtime_set(out, 0, 0)
	wtime_add_ms(out, now)
	return IO_OK


# The environment of node in net; seed fixes its fault and crash draws.
sim_env* sim_env_new(sim_net* net, int node, int seed, int wall_base_sec):
	sim_env* env = new sim_env()
	env.net = net
	env.node = node
	env.wall_base_sec = wall_base_sec
	env.wall_offset_ms = 0
	env.clock = wclock_custom_new(sim_env_read, cast(void*, env))
	env.fs = fake_fs_new(seed * 7919 + node)
	env.crash_rng = prng_new(seed * 104729 + node * 31 + 1)
	return env


void sim_env_free(sim_env* env):
	wclock_free(env.clock)
	fake_fs_free(env.fs)
	prng_free(env.crash_rng)
	free(env)


wclock* sim_env_clock(sim_env* env):
	return env.clock


file_ops* sim_env_ops(sim_env* env):
	return fake_fs_ops(env.fs)


# Steps this node's wall clock (either sign); monotonic time is untouched.
void sim_env_jump_wall_ms(sim_env* env, int ms):
	env.wall_offset_ms = env.wall_offset_ms + ms


# Power loss on this node: unsynced storage state is partly lost (lib/fake_fs.w).
void sim_env_crash(sim_env* env):
	fake_fs_crash(env.fs, env.crash_rng)
