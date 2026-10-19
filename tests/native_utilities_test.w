# wbuild: tool=tools/javascript_unicode.w tool=tools/html_entities.w tool=tools/ppm_to_png.w tool=tests/data/tz/make_fixtures.w
# wbuild: deps=libs/extras/javascript/unicode_12_1.ranges deps=libs/extras/javascript/unicode.w deps=libs/extras/html/entities.json deps=libs/extras/html/entities.w
import tools.host_tools
import graphics.image.png

int main():
	ht_checked(ht_command(c"bin/tz_make_fixtures --check"))
	ht_checked(ht_command(c"bin/javascript_unicode --check"))
	ht_checked(ht_command(c"bin/html_entities --check"))
	char* directory = ht_temp()
	char* input = path_join(directory, c"in.ppm")
	char* output = path_join(directory, c"out.png")
	list[char*] command = ht_command(c"bin/ppm_to_png")
	command.push(input)
	command.push(output)
	string_builder* ppm = string_from(c"P6\n# a comment\n2 1\n255\n")
	string_append_bytes(ppm, c"\xff\x00\x00\x00\xff\x00", 6)
	ht_write(input, ppm.data, ppm.length)
	ht_checked(command)
	string_builder* encoded = ht_read(output)
	wresult[rgba_image*]* decoded = png_decode_n(encoded.data, encoded.length, image_default_limits())
	ht_require(decoded.ok && decoded.value.width == 2 && decoded.value.height == 1, c"PPM conversion produced invalid PNG")
	ht_require(bytes_equal(decoded.value.pixels, 8, c"\xff\x00\x00\xff\x00\xff\x00\xff", 8), c"PPM conversion changed pixels")
	for char* bad in ht_split(c"P6\n# no terminating newline|P6\n2 1\n255\nx|P6\n-1 1\n255\n|P6\n999999999999999999999 1\n255\n|P6\n1 1\n65535\n", '|'):
		ht_write(input, bad, strlen(bad))
		ht_require(ht_run(command, 0, 0, 3000).status != 0, c"invalid PPM accepted")
		string_builder* unchanged = ht_read(output)
		ht_require(bytes_equal(encoded.data, encoded.length, unchanged.data, unchanged.length), c"invalid PPM overwrote PNG")
	ht_cleanup()
	println(c"native utility checks OK")
	return 0
