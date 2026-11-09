/*
photo_fx: apply graphics.effects photo effects to an image from the
command line, on the GPU through framebuffer objects when a GL display
is reachable and on the CPU reference otherwise.

	./wbuild photo_fx            # or: bin/wv2 x64 examples/photo/photo_fx.w -o bin/photo_fx
	bin/photo_fx IN.png OUT.png --brightness 0.1 --contrast 1.2 --blur 3 --sharpen --vignette 0.5
	bin/photo_fx IN.jpg OUT.png --lut sepia --lut-amount 0.8
	bin/photo_fx pattern:320x200 OUT.png --edges        # synthetic input
	bin/photo_fx --compare A.png B.png --tolerance 3    # per-channel diff

Input is PNG or JPEG (by signature); output is always PNG. The GPU path
opens a small window only to get a context -- every pass renders
off-screen at the image's own resolution. Negative values need the
`=` form (`--brightness=-0.2`): a bare `-0.2` reads as a flag.

Design notes: docs/projects/effects.md
*/
# wbuild: binary=photo_fx arch=x64
# The sample's own end-to-end test: a 7-pass chain on the CPU, the same
# chain on the GPU when a display is reachable (the CPU otherwise, with
# a message), the two compared, then a real PNG decoded and graded. The
# GPU/CPU tolerance is 8 levels because sharpen (center weight 3 at 0.5)
# amplifies the odd one-level rounding difference of the passes before it.
# wbuild: target=photo_fx_test tag=tests_x64 dep=photo_fx data=docs/images/ui_demo_light.png
# wbuild: step="bin/photo_fx pattern:96x64 bin/photo_fx_test_cpu.png --gamma 1.1 --brightness 0.1 --contrast 1.2 --saturation 1.3 --lut warm --blur 2 --sharpen 0.5 --vignette 0.5 --cpu" expect_stdout="96x64, 7 passes (cpu)"
# wbuild: step="bin/photo_fx pattern:96x64 bin/photo_fx_test_auto.png --gamma 1.1 --brightness 0.1 --contrast 1.2 --saturation 1.3 --lut warm --blur 2 --sharpen 0.5 --vignette 0.5" expect_stdout="96x64, 7 passes ("
# wbuild: step="bin/photo_fx --compare bin/photo_fx_test_cpu.png bin/photo_fx_test_auto.png --tolerance 8" expect_stdout="images match"
# wbuild: step="bin/photo_fx bin/photo_fx_test_cpu.png bin/photo_fx_test_copy.png --cpu" expect_stdout="0 passes (cpu)"
# wbuild: step="bin/photo_fx --compare bin/photo_fx_test_cpu.png bin/photo_fx_test_copy.png" expect_stdout="max channel difference 0"
# wbuild: step="bin/photo_fx --compare bin/photo_fx_test_cpu.png pattern:96x64 --tolerance 2" expect_fail expect_stdout="images differ"
# wbuild: step="bin/photo_fx docs/images/ui_demo_light.png bin/photo_fx_test_ui.png --lut sepia --vignette=0.6 --edges --cpu" expect_stdout="320x680, 3 passes (cpu)"
import lib.lib
import lib.args
import graphics.gl
import graphics.window
import graphics.effects_core
import graphics.effects_cpu
import graphics.effects
import graphics.image.image
import examples.photo.photo_lib


void photo_fx_usage():
	println2(c"usage: photo_fx IN OUT.png [effects] [--cpu | --gl]")
	println2(c"       photo_fx --compare A.png B.png [--tolerance N]")
	println2(c"IN is a PNG, a JPEG or pattern:WxH. Effects (applied in this order):")
	println2(c"  --black B --white W --gamma G     input levels and gamma")
	println2(c"  --brightness B --contrast C --saturation S")
	println2(c"  --lut identity|warm|cool|sepia|mono|STRIP.png [--lut-amount A] [--lut-size N]")
	println2(c"  --blur RADIUS                     separable Gaussian, up to 32 px")
	println2(c"  --sharpen [AMOUNT] --edges --emboss")
	println2(c"  --vignette [AMOUNT] [--vignette-radius R] [--vignette-softness S]")
	println2(c"Negative values need the = form: --brightness=-0.2")


# Per-channel comparison of two images; 0 when they match within
# tolerance, 1 when they differ, 2 on a load error.
int photo_fx_compare(char* a_path, char* b_path, int tolerance):
	rgba_image* a = photo_load(a_path)
	rgba_image* b = photo_load(b_path)
	if ((a == 0) || (b == 0)): return 2
	if ((a.width != b.width) || (a.height != b.height)):
		println(c"photo_fx: images differ in size")
		return 1
	int worst = 0
	for i in range(a.width * a.height * 4):
		int diff = (a.pixels[i] & 255) - (b.pixels[i] & 255)
		if (diff < 0): diff = 0 - diff
		if (diff > worst): worst = diff
	print(c"photo_fx: max channel difference ")
	println(itoa(worst))
	rgba_image_free(a)
	rgba_image_free(b)
	if (worst > tolerance):
		println(c"photo_fx: images differ")
		return 1
	println(c"photo_fx: images match")
	return 0


# The GPU path: 0 when no context could be had or the GPU run failed,
# so the caller falls back to the CPU.
rgba_image* photo_fx_gpu(list[fx_effect*] chain, rgba_image* image):
	gfx_window* win = gfx_window_open(c"photo_fx", 64, 64)
	if (win == 0): return 0
	fx_gl g
	fx_gl_init(&g)
	rgba_image* out = fx_gl_run_image(&g, chain, image)
	for i in range(chain.length): fx_gl_release_effect(chain[i])
	fx_gl_destroy(&g)
	gfx_window_destroy(win)
	return out


int main(int argc, int argv):
	args_init(argc, argv)
	args_declare_bool(c"cpu")
	args_declare_bool(c"gl")
	args_declare_bool(c"compare")
	args_declare_bool(c"help")
	if (args_has_flag(c"help")):
		photo_fx_usage()
		return 0
	if (args_has_flag(c"compare")):
		if (args_positional_count() != 2):
			photo_fx_usage()
			return 2
		int tolerance = 0
		char* tolerance_value = args_value(c"tolerance")
		if (tolerance_value != 0): tolerance = atoi(tolerance_value)
		return photo_fx_compare(args_positional(0), args_positional(1), tolerance)
	photo_settings settings
	if (photo_settings_from_args(&settings) == 0): return 2
	if (args_positional_count() != 2):
		photo_fx_usage()
		return 2
	char* in_path = args_positional(0)
	char* out_path = args_positional(1)
	rgba_image* image = photo_load(in_path)
	if (image == 0): return 1
	list[fx_effect*] chain = photo_build_chain(&settings)

	rgba_image* out = 0
	char* backend = c"cpu"
	if (args_has_flag(c"cpu") == 0):
		out = photo_fx_gpu(chain, image)
		if (out != 0): backend = c"gl"
		else if (args_has_flag(c"gl")):
			print_error(c"photo_fx: --gl given but no GL context is available\n")
			return 1
		else: print_error(c"photo_fx: no GL display; using the CPU reference\n")
	if (out == 0): out = fx_cpu_run_image(chain, image)

	if (photo_write_png(out_path, out.width, out.height, out.pixels) == 0):
		print_error(c"photo_fx: cannot write ")
		print_error(out_path)
		print_error(c"\n")
		return 1
	print(c"photo_fx: wrote ")
	print(out_path)
	print(c" ")
	print(itoa(out.width))
	print(c"x")
	print(itoa(out.height))
	print(c", ")
	print(itoa(chain.length))
	print(c" passes (")
	print(backend)
	println(c")")
	photo_free_chain(chain)
	rgba_image_free(out)
	rgba_image_free(image)
	return 0
