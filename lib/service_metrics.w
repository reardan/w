/*
Opt-in service metric sampling. Importing this module wires the existing
owner counters into lib.metrics without adding a dependency from the
scheduler, executor or allocator to diagnostics. Sampling allocates
nothing; the caller chooses the cadence and owns m.

A metrics instance represents one owner for each category: sampling a
second scheduler/executor replaces that category rather than silently
summing stale snapshots. Sample schedulers, arenas and budgets only on
their owner thread; executor_get_stats provides a locked snapshot and
may be called from any thread. Serialize access to a shared metrics.

Allocation samplers are alternatives: use the enclosing budget OR its
arena, since a refused arena allocation may also count as a budget
failure. These are lifetime snapshots, so repeated samples do not count
a failure twice. Owners and metrics have independent lifetimes; no
pointers are retained by sampling.
*/
import lib.metrics
import lib.task
import lib.executor
import lib.arena


void metrics_sample_scheduler(metrics* m, task_scheduler* s):
	metrics_set(m, METRIC_TASKS_PENDING, s.active_count)


void metrics_sample_executor(metrics* m, executor* ex):
	executor_stats s
	executor_get_stats(ex, &s)
	metrics_set(m, METRIC_JOBS_QUEUED, s.queued_jobs)
	metrics_set(m, METRIC_BYTES_QUEUED, s.queued_bytes)
	metrics_set(m, METRIC_WORKERS_RUNNING, s.running_jobs)
	# Workers blocked waiting for work. Running jobs are opaque; their
	# internal syscall wait state is not observable by the executor.
	metrics_set(m, METRIC_WORKERS_BLOCKED, s.idle_workers)


void metrics_sample_arena(metrics* m, arena* a):
	metrics_set(m, METRIC_ALLOC_FAILURES, a.alloc_failures)


void metrics_sample_budget(metrics* m, mem_budget* b):
	metrics_set(m, METRIC_ALLOC_FAILURES, b.failures)
