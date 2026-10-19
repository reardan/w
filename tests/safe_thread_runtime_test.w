# wbuild: step="bin/wv2 --strict tests/safe_thread_runtime_fixture.w -o bin/safe_thread_runtime"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_thread_runtime"
# wbuild: step="bin/safe_thread_runtime"
# wbuild: step="bin/wv2 --strict --safe tests/safe_thread_runtime_fixture.w -o bin/safe_thread_runtime"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_thread_runtime"
# wbuild: step="bin/wv2 --strict --no-regs --no-inline tests/safe_thread_runtime_fixture.w -o bin/safe_thread_runtime"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_thread_runtime"
# wbuild: step="bin/wv2 --strict --inline tests/safe_thread_runtime_fixture.w -o bin/safe_thread_runtime"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_thread_runtime"
# wbuild: step="bin/wv2 x64 --strict tests/safe_thread_runtime_fixture.w -o bin/safe_thread_runtime64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_thread_runtime64"
# wbuild: step="bin/safe_thread_runtime64"
# wbuild: step="bin/wv2 x64 --strict --safe tests/safe_thread_runtime_fixture.w -o bin/safe_thread_runtime64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_thread_runtime64"
# wbuild: step="bin/wv2 x64 --strict --no-regs --no-inline tests/safe_thread_runtime_fixture.w -o bin/safe_thread_runtime64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_thread_runtime64"
# wbuild: step="bin/wv2 x64 --strict --inline tests/safe_thread_runtime_fixture.w -o bin/safe_thread_runtime64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_thread_runtime64"
# The checked thread runtime rides lib/thread.w and lib/thread_heap.w,
# which support Linux x86/x64 only; other targets fail closed at compile
# time (docs/projects/safe_mode.md "Thread transfer and spawn/join").
int main():
	return 0
