# Cross-host structural gate: compiler-emitted iOS binaries need no Apple
# SDK to build or inspect. Actual UIKit execution: tools/ios/smoke.sh.
# wbuild: target=ios_target_test tag=tests dep=wv2 dep=wtest
# wbuild: step="bin/wtest archs -f tests/wtest/manifest_ios.json graphics/ios/demo.w --check" expect_stdout="arm64_ios graphics/ios/demo.w: OK" expect_stdout="arm64_ios_sim graphics/ios/demo.w: OK"
# wbuild: step="bin/wv2 arm64_darwin --strict graphics/ios/demo.w -o bin/ios_macos_test"
# wbuild: step="bin/wv2 arm64_ios --strict graphics/ios/demo.w -o bin/ios_device_test"
# wbuild: step="bin/wv2 arm64_ios_sim --strict graphics/ios/demo.w -o bin/ios_simulator_test"
# wbuild: step="bin/wv2 check --json arm64_ios graphics/ios/demo.w"
# wbuild: step="bin/wv2 arm64_ios_sim check --json graphics/ios/demo.w"
# wbuild: step="bin/wv2 symbols --json arm64_ios graphics/ios/demo.w" expect_stdout="\"arch\": \"arm64_ios\""
# wbuild: step="bin/wv2 symbols --json arm64_ios_sim graphics/ios/demo.w" expect_stdout="\"arch\": \"arm64_ios_sim\""
# wbuild: step="bin/wv2 deps arm64_ios graphics/ios/demo.w" expect_stdout="lib/__arch__/arm64_ios/syscalls.w"
# wbuild: step="bin/wv2 deps arm64_ios_sim graphics/ios/demo.w" expect_stdout="lib/__arch__/arm64_ios_sim/syscalls.w"
# wbuild: step="bin/wv2 tests/ios_target_test.w -o bin/ios_target_test"
# wbuild: step="bin/ios_target_test"
import lib.testing
import lib.assert

void ios_check_image(char* path, int platform):
	int fd = open(path, 0, 0)
	asserts(c"iOS image opens", fd >= 0)
	int size = file_size(fd)
	asserts(c"iOS image has a Mach-O header", size >= 32)
	char* image = cast(char*, malloc(size))
	assert_equal(size, read(fd, image, size))
	close(fd)
	assert_equal(cast(int, 0xfeedfacf), load_int32(image))
	assert_equal(0x0100000c, load_int32(image + 4))
	assert_equal(2, load_int32(image + 12))  # MH_EXECUTE
	asserts(c"PIE enabled", load_int32(image + 24) & 0x200000)
	int minimum = 17 << 16
	if (platform == 1): minimum = 12 << 16
	int count = load_int32(image + 16)
	int end = 32 + load_int32(image + 20)
	asserts(c"load commands within file", end <= size)
	int offset = 32
	int platforms = 0
	int entries = 0
	int bridges = 0
	int signatures = 0
	for i in range(count):
		asserts(c"load command header in range", offset + 8 <= end)
		int cmd = load_int32(image + offset)
		int length = load_int32(image + offset + 4)
		asserts(c"load command size aligned and in range", length >= 8 && (length & 7) == 0 && offset + length <= end)
		char* lc = image + offset
		if (cmd == 50):
			assert_equal(24, length)
			assert_equal(platform, load_int32(lc + 8))
			assert_equal(minimum, load_int32(lc + 12))
			assert_equal(minimum, load_int32(lc + 16))
			platforms = platforms + 1
		else if (cmd == cast(int, 0x80000028)):
			assert_equal(24, length)
			asserts(c"entry is within executable", load_int32(lc + 8) < size)
			assert_equal(0, load_int32(lc + 12))
			entries = entries + 1
		else if (cmd == 25):
			asserts(c"segment header in range", length >= 72)
			int prot = load_int32(lc + 60)
			asserts(c"W xor X", (prot & 6) != 6)
		else if (cmd == 12):
			asserts(c"dylib header in range", length >= 24)
			int name_offset = load_int32(lc + 8)
			asserts(c"dylib name in command", name_offset >= 24 && name_offset < length)
			if (strcmp(lc + name_offset, c"@executable_path/Frameworks/WIOS.framework/WIOS") == 0): bridges = bridges + 1
		else if (cmd == 29):
			assert_equal(16, length)
			asserts(c"signature in image", load_int32(lc + 8) + load_int32(lc + 12) <= size)
			signatures = signatures + 1
		offset = offset + length
	assert_equal(end, offset)
	assert_equal(1, platforms)
	assert_equal(1, entries)
	assert_equal(1, bridges)
	assert_equal(1, signatures)
	free(image)

void test_ios_device_platform():
	ios_check_image(c"bin/ios_device_test", 2)

void test_ios_simulator_platform():
	ios_check_image(c"bin/ios_simulator_test", 7)

void test_macos_platform_unchanged():
	ios_check_image(c"bin/ios_macos_test", 1)
