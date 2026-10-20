# expect_fail
# expect_stderr: float16 and bfloat16 are not supported by value in external ABIs; use float32 or pointers
import lib.lib
c_lib "libm.so.6"
extern float32 sqrtf(float16 value)
int main(): return 0
