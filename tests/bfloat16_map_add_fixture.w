# expect_fail
# expect_stderr: map add does not support bfloat16 values
# Narrow-float map += works; the single-probe .add helper intentionally
# rejects narrow storage formats, matching float16.
void main():
	map[int, bfloat16] values = new map[int, bfloat16]
	values.add(1, 0.5)
