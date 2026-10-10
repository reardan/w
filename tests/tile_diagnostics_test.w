import lib.testing
import lib.file
import lib.process
import lib.str

void tile_reject(char* region, char* message):
	char* path = f"bin/tile_reject_{getpid()}.w"
	char* source = f"import lib.lib\nvoid __w_gpu_launch_tiles(char* name, int n, int width, char* vals, int count):\n\tpass\nvoid bad(float32* a, float32* b, float32* c, int n, const float32* ro):\n{region}\nint main():\n\treturn 0\n"
	assert1(file_write_text(path, source))
	for mode in range(2):
		char** args = strv_new(9)
		strv_set(args, 0, c"bin/wv2")
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"x64")
		strv_set(args, 4, path)
		if mode: strv_set(args, 5, c"--streaming")
		process_result* result = process_run(c"bin/wv2", args, 0, 0, 60000)
		assert1(result != 0)
		if result.status == 0 || index_of(result.stdout_text, message) < 0:
			println(source)
			println(result.stdout_text)
			println(result.stderr_text)
		assert1(result.status != 0)
		assert_contains(result.stdout_text, message)
		assert_contains(result.stdout_text, c"\"severity\": \"error\"")
		process_result_free(result)
		free(cast(char*, args))
	unlink(path)
	free(path)
	free(source)

void test_tile_shape_and_type_diagnostics():
	tile_reject(c"\tgpu[0] for tile in range(n):\n\t\tc[tile] = a[tile]", c"tile width must be")
	tile_reject(c"\tgpu[1025] for tile in range(n):\n\t\tc[tile] = a[tile]", c"tile width must be")
	tile_reject(c"\tgpu[4] for tile in range(n):\n\t\tint x = a[tile]", c"explicit tile-body locals must be scalar")
	tile_reject(c"\tgpu[4] for tile in range(n):\n\t\tn = 1", c"tile captures and loop indices are read-only")
	tile_reject(c"\tgpu[4] for tile in range(n):\n\t\ttile = 1", c"tile captures and loop indices are read-only")
	tile_reject(c"\tgpu[4] for tile in range(n):\n\t\tc[0] = 1", c"tile indexing requires an integer tile index")
	tile_reject(c"\tgpu[1024] for tile in range(n):\n\t\tc[tile] = a[tile + 256]", c"tile memory indexing requires the direct region tile identifier")
	tile_reject(c"\tgpu[4] for tile in range(n):\n\t\tindex := tile\n\t\tc[index] = 1", c"tile memory indexing requires the direct region tile identifier")
	tile_reject(c"\tgpu[4] for tile in range(n):\n\t\tro[tile] = 1", c"cannot store through a const tile pointer")
	tile_reject(c"\tgpu[4] for tile in range(n):\n\t\tint x = 0.5", c"tile local initializer would narrow")
	tile_reject(c"\tgpu[4] for tile in range(n):\n\t\tint x = 1\n\t\tx = 0.5", c"tile assignment would narrow")
	tile_reject(c"\tgpu[4] for tile in range(n):\n\t\tc[tile] = a[tile] % 2", c"tile remainder")
	tile_reject(c"\tgpu[4] for tile in range(n):\n\t\tc[tile] = n[tile]", c"tile memory operations require a float32 pointer")

void test_tile_control_and_syntax_diagnostics():
	tile_reject(c"\tgpu[4] for tile in range(-0.5 < -0.75):\n\t\tc[tile] = 1", c"tile range bound requires a host integer expression")
	tile_reject(c"\tgpu[4] for tile in range(n):\n\t\tif tile:\n\t\t\tc[tile] = 1", c"uniform scalar int")
	tile_reject(c"\tgpu[4] for tile in range(n):\n\t\tfor int i in range(tile):\n\t\t\tc[tile] = 1", c"uniform scalar int")
	tile_reject(c"\tgpu[4] for tile in range(tile_program_id()):\n\t\tc[tile] = 1", c"tile range bound requires a host integer expression")
	tile_reject(c"\tgpu[4] for tile in range(n):\n\t\tc[tile] = sqrt(4)", c"tile bodies support only tile builtins")
	tile_reject(c"\tgpu[4] for tile in range(n):\n\t\tint x = 1\n\t\tint x = 2", c"duplicate tile local")
	tile_reject(c"\tgpu[4] for tile in range(n):\n\t\tint x = 2147483648", c"tile integer literal is too large")

void test_tile_matrix_diagnostics():
	tile_reject(c"\tgpu[4] for tile in range(n):\n\t\tx := tile_zero(16, 16)", c"rank-two tile operations require gpu[1]")
	tile_reject(c"\tgpu[1] for tile in range(n):\n\t\tx := tile_zero(8, 16)", c"constant 16 by 16")
	tile_reject(c"\tgpu[1] for tile in range(n):\n\t\tx := tile_zero(16.0, 16)", c"constant 16 by 16")
	tile_reject(c"\tgpu[1] for tile in range(n):\n\t\tx := tile_program_id(0)", c"tile_program_id expects no arguments")
	tile_reject(c"\tgpu[1] for tile in range(n):\n\t\tx := tile_zero(16)", c"tile_zero expects two static dimensions")
	tile_reject(c"\tgpu[1] for tile in range(n):\n\t\tx := tile_load(a, 0)", c"tile_load expects")
	tile_reject(c"\tgpu[1] for tile in range(n):\n\t\tx := tile_load(a, 0, 0, n, 1, n, n, 8, 16)", c"constant 16 by 16")
	tile_reject(c"\tgpu[1] for tile in range(n):\n\t\tx := dot(a[tile], b[tile])", c"compatible rank-two float32 tiles")
	tile_reject(c"\tgpu[1] for tile in range(n):\n\t\tx := dot(a[tile])", c"dot expects two")
	tile_reject(c"\tgpu[1] for tile in range(n):\n\t\ttile_store(c, 0)", c"tile_store expects")
	tile_reject(c"\tgpu[1] for tile in range(n):\n\t\ttile_store(c, 0, 0, n, 1, n, n, 1)", c"tile_store requires a rank-two float32 tile")
