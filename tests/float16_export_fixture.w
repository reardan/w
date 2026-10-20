# expect_fail
# wfixture: wasm
# expect_stderr: float16 and bfloat16 are not supported by value in external ABIs; use float32 or pointers
export float16 narrow(float32 value): return value
int main(): return 0
