# wbuild: step="bin/wv2 --strict tests/safe_sync_runtime_fixture.w -o bin/safe_sync_runtime"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_sync_runtime"
# wbuild: step="bin/safe_sync_runtime"
# wbuild: step="bin/wv2 --strict --safe tests/safe_sync_runtime_fixture.w -o bin/safe_sync_runtime"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_sync_runtime"
# wbuild: step="bin/wv2 --strict --no-regs --no-inline tests/safe_sync_runtime_fixture.w -o bin/safe_sync_runtime"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_sync_runtime"
# wbuild: step="bin/wv2 --strict --inline tests/safe_sync_runtime_fixture.w -o bin/safe_sync_runtime"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_sync_runtime"
# wbuild: step="bin/wv2 x64 --strict tests/safe_sync_runtime_fixture.w -o bin/safe_sync_runtime64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_sync_runtime64"
# wbuild: step="bin/safe_sync_runtime64"
# wbuild: step="bin/wv2 x64 --strict --safe tests/safe_sync_runtime_fixture.w -o bin/safe_sync_runtime64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_sync_runtime64"
# wbuild: step="bin/wv2 x64 --strict --no-regs --no-inline tests/safe_sync_runtime_fixture.w -o bin/safe_sync_runtime64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_sync_runtime64"
# wbuild: step="bin/wv2 x64 --strict --inline tests/safe_sync_runtime_fixture.w -o bin/safe_sync_runtime64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_sync_runtime64"
# Checked mutexes, guards and atomics ride lib/safe_thread.w, which
# supports Linux x86/x64 only (docs/projects/safe_mode.md "Synchronization:
# guarded mutexes and atomics"). Each run repeats the contention rounds, so
# a lost update or a guard that fails to unlock shows up as a wrong count or
# a hang; W_DEBUG_ALLOC=1 runs report leaked or double-freed payloads.
int main():
	return 0
