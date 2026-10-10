# GPU-independent tile compiler and launch-ABI fixture. The stand-in runtime
# records launches without loading libcuda or executing device instructions.
import lib.lib
import lib.assert

char* __w_ptx_module();
int tile_launch_count

void tile_shadow(float32* gpu):
	gpu[0] = 1

void __w_gpu_launch_tiles(char* name, int n, int width, int threads, char* vals, int count):
	assert1(threads == 256)
	assert1(n == 9)
	assert1(width == 1024 || width == 1)
	assert1(count >= 4)
	assert1(load_i(vals + (count - 1) * 8, 8) == n)
	tile_launch_count += 1

void tile_vector_fixture(float32* a, float32* b, float32* c, int n):
	gpu[1024] for tile in range(n):
		int offset = 2
		float32 scale = 3
		value := a[tile] + b[tile]
		if n > 0 && offset == 2:
			for int step in range(0, 2):
				value += scale
		else:
			value -= 1
		c[tile] = value

void tile_matrix_fixture(float32* a, float32* b, float32* c, int m, int n, int k, int programs):
	gpu[1] for tile in range(programs):
		int columns = (n + 15) / 16
		int row = tile_program_id() / columns * 16
		int col = tile_program_id() % columns * 16
		acc := tile_zero(16, 16)
		for int block in range((k + 15) / 16):
			left := tile_load(a, row, block * 16, k, 1, m, k, 16, 16)
			right := tile_load(b, block * 16, col, n, 1, k, n, 16, 16)
			acc += dot(left, right)
		tile_store(c, row, col, n, 1, m, n, acc)

void tile_header_fixture(float32* a, float32* b, float32* c, int n):
	# Each subexpression is one, except the final remainder (zero).
	gpu[1024] for tile in range(+n - 1 + (n > 0) + (n < 10) + (n <= 9) + (n >= 9) + (n == 9) + (n != 0) + (!0) + (0 || 1) + (1 && 1) - 8 + (n % 3) + n / 3 - 3 + (1 || (n / 0)) - 1 + (0 && (n / 0))):
		c[tile] = a[tile] * b[tile] / 2

int main():
	float32[9] values
	float32* p = &values[0]
	tile_shadow(p)
	assert1(values[0] == 1)
	tile_vector_fixture(p, p, p, 9)
	tile_matrix_fixture(p, p, p, 9, 9, 9, 9)
	tile_header_fixture(p, p, p, 9)
	assert1(tile_launch_count == 3)
	print(__w_ptx_module())
	return 0
